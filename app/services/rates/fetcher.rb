# frozen_string_literal: true

require "net/http"

module Rates
  # Fetches published exchange rates and stores them.
  #
  # Every source is declared in db/exchange_rate_sources.yml. This class knows
  # how to make an HTTP request and how to write a row; it knows nothing about
  # any particular feed. Adding a new publisher is a YAML entry plus a parser
  # class — no change here.
  class Fetcher
    class << self
      def enabled?
        ENV.fetch("FETCH_EXCHANGE_RATES", Rails.env.production? ? "true" : "false") == "true"
      end

      # Every declared source, keyed by name so a caller can see which failed.
      def fetch_and_store!(date: Date.current)
        RateSourceConfig.all.index_with { |source| fetch_and_store(source, date) }
      rescue StandardError => e
        Rails.logger.error "Rates::Fetcher: #{e.message}"
        { error: e.message }
      end

      def fetch_and_store(source, date = Date.current)
        config = RateSourceConfig.fetch_config(source)
        return failure("unknown source #{source}") unless config

        # A source may offer several files covering different stretches of time
        # — the ECB has today's rates, the last 90 days, and an archive back to
        # 1999. Try them cheapest first and stop at the one that actually holds
        # the period asked for: the 90-day file is 0.1 MB against the archive's
        # 7.8 MB, and most gaps are recent.
        parsed = nil
        fetched = false
        unreadable = false

        candidate_urls(config, date).each do |url|
          body = fetch_url(url)
          next unless body

          fetched = true
          result = parser_for(config).parse(body, requested_date: date)

          # A parser may answer with ONE period or with MANY. One is the monthly
          # case. Many is what a DAILY source needs: its history arrives as a
          # single file holding every banking day of a year, so one request
          # yields hundreds of one-day spans, and fetching them a day at a time
          # is not on offer.
          if result.is_a?(Hash) || result.is_a?(Array)
            parsed = Array.wrap(result).select { |p| p.is_a?(Hash) && p[:rates].present? }
            parsed = nil if parsed.empty?
            break if parsed
            unreadable = true
          elsif result.nil?
            unreadable = true
          end
          # :no_data_yet — this file does not reach that period. Try a wider
          # one.
        end

        return failure("Failed to fetch #{source}") unless fetched

        # nil from every file means THE RESPONSE DID NOT LOOK LIKE THE FEED WE
        # EXPECT. That is the one worth an email: a publisher changing a column
        # name, a date format or a URL convention breaks us silently otherwise,
        # and the first symptom would be a report months later with no rate.
        if parsed.nil? && unreadable
          return failure("#{source}: the response did not match the expected format. " \
                         "The publisher may have changed it.")
        end

        # Recognised everywhere, but no file reaches that period. Normal, not a
        # fault — a month-average source is empty until its month ends, and no
        # archive reaches before the publisher existed.
        return { success: true, count: 0, not_published: true } unless parsed

        stored = parsed.sum do |period|
          store_rates(period[:rates], config["base"], period[:valid_from],
                      period[:valid_to], source).size
        end

        # The OUTER span — what this fetch covered in total, which for a daily
        # source is the whole stretch the file reached, not one of its days.
        { success: true, count: stored,
          valid_from: parsed.filter_map { |p| p[:valid_from] }.min,
          valid_to:   parsed.filter_map { |p| p[:valid_to] }.max,
          periods:    parsed.size }
      end

      # Fetch and parse WITHOUT storing: { currency => rate }, or nil. For the
      # coverage probe, which must not write — the app stores only currencies it
      # supports, and probing is a question, not a fetch.
      #
      # Shares the whole candidate-url and parser path with fetch_and_store, so
      # a feed cannot be readable by one and not the other.
      def probe(source, date = Date.current)
        config = RateSourceConfig.fetch_config(source)
        return nil unless config

        candidate_urls(config, date).each do |url|
          body = fetch_url(url)
          next unless body

          result = parser_for(config).parse(body, requested_date: date)
          return result[:rates] if result.is_a?(Hash)
        end

        nil
      end

      private

      def failure(message)
        { success: false, error: message }
      end

      # In order of what to try. For a CURRENT period the ordinary url is right.
      # For a past one, prefer whichever historical file is smallest and still
      # likely to reach it — asking the ECB for last month should not pull 7.8
      # MB of rates going back to 1999.
      def candidate_urls(config, date)
        urls = []

        # A DAILY source reaches for the multi-day files FIRST, even for the
        # current month, and that is not an optimisation — it is the only way to
        # get a whole month.
        #
        # The ordinary `url` of a daily feed holds ONE day. Asking it for July
        # returns a single span, the fetcher stores it, and every other day of
        # July silently has no rate: a gap that looks like a completed fetch.
        # The 90-day file covers the current month whole, so it is the right
        # first choice for anything recent; the archive answers for older.
        historical = date < Date.current.beginning_of_month
        if historical || RateSourceConfig.daily?(config)
          urls << config["history_url"] if config["history_url"] &&
                                           (!historical || date >= 120.days.ago.to_date)
          urls << config["archive_url"]
        end

        urls << config["url"]
        urls << config["fallback_url"]
        urls.compact.uniq.map { |u| format_url(u, date) }
      end

      # %{year}, %{month} and %{month2}. Both forms exist because the feeds
      # disagree: HMRC's own files are monthly_csv_2026-8.csv and 2026-08 is a
      # 404, while the Bundesbank wants startPeriod=2026-06 and rejects 2026-6.
      def format_url(template, date)
        return template unless template.include?("%{")

        format(template,
               year:   date.year,
               month:  date.month,
               month2: format("%02d", date.month))
      end

      # `parser: hmrc_csv` in the YAML means Rates::HmrcCsvParser — a convention
      # rather than a lookup table, so a new parser is a class and one line of
      # YAML, with no third place to remember.
      def parser_for(config)
        name = config["parser"].to_s
        raise "no parser declared" if name.empty?

        klass = "Rates::#{name.camelize}Parser".constantize
        raise "#{klass} cannot parse" unless klass.respond_to?(:parse)

        klass
      end

      def fetch_url(url)
        uri = URI(url)
        Net::HTTP.start(uri.host, uri.port,
                        use_ssl: uri.scheme == "https",
                        open_timeout: 10,
                        read_timeout: 15) do |http|
          response = http.get(uri.request_uri)
          next nil unless response.is_a?(Net::HTTPSuccess)

          # Net::HTTP hands back ASCII-8BIT regardless of the charset header, so
          # HMRC's "Currency Units per £1" arrives as raw bytes and matches no
          # UTF-8 string. Every feed here is UTF-8; scrub rather than raise on a
          # stray byte, because losing one character beats losing the fetch. The
          # Bundesbank's CSV begins with a byte-order mark, which would
          # otherwise become part of the first header cell and match nothing.
          response.body.dup.force_encoding(Encoding::UTF_8).scrub.delete_prefix("﻿")
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
        Rails.logger.warn "Rates::Fetcher: network error fetching #{url}: #{e.message}"
        nil
      end

      # Only currencies the app knows. A feed offering 170 of them (HMRC does)
      # would otherwise fill the table with rates nobody can select.
      def store_rates(rates, base_currency, valid_from, valid_to, source)
        return [] unless CurrencyConfig.available.include?(base_currency)

        rates.each_with_object([]) do |(currency, rate), stored|
          next if currency == base_currency
          next unless CurrencyConfig.available.include?(currency)

          stored << upsert_rate(base_currency, currency, rate, valid_from, valid_to, source)
        end
      end

      # Keyed on the SPAN, not on a single date. Re-fetching a month it already
      # holds updates that row rather than colliding with it — and the database
      # rejects an overlapping span outright, so a source that changed its mind
      # about a period cannot quietly produce two answers.
      def upsert_rate(from, to, rate, valid_from, valid_to, source)
        record = ExchangeRate.find_or_initialize_by(
          from_currency: from, to_currency: to, valid_from: valid_from, source: source
        )
        record.update!(rate: rate.round(6), valid_to: valid_to, effective_date: valid_from)
        record
      end
    end
  end
end
