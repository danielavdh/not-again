# frozen_string_literal: true

# Reads db/exchange_rate_sources.yml. Adding a rate source is a YAML edit.
#
# Deliberately the same shape as TaxSchemeConfig: a memoised hash built once
# from a file, with reload! for the console and the tests. Nothing here knows
# about countries or tax — see the file's own header for why that separation
# matters.
class RateSourceConfig
  PATH = Rails.root.join("db", "exchange_rate_sources.yml")

  class << self
    def all
      config.keys
    end

    def exists?(source)
      config.key?(source.to_s)
    end

    # The currency this feed publishes against. Everything else is reached by
    # cross-rate through it.
    def base_for(source)
      config.dig(source.to_s, "base")
    end

    # source => base, the shape ExchangeRate's cross-rating expects.
    def bases
      @bases ||= config.transform_values { |c| c["base"] }.freeze
    end

    # Which source a REPORT displayed in this currency should read.
    #
    # Only sources marked display_default are eligible, because a base currency
    # does not identify a source on its own: the Bundesbank publishes against
    # EUR too, but a report wants the ECB, not a tax series. Which source an
    # AUTHORITY requires for a submission is a tax rule and belongs in the rules
    # file.
    def display_source_for(currency)
      display_sources[currency.to_s.upcase]
    end

    # currency => source, for the sources that declare display_default.
    def display_sources
      @display_sources ||= config
        .select { |_k, c| c["display_default"] }
        .each_with_object({}) { |(key, c), h| h[c["base"]] ||= key }
        .freeze
    end

    # Every source TIER 1 can reach — not merely the defaults, but the defaults
    # plus everything the report's currency dropdown offers, because a reader
    # may pick any of them.
    #
    # The Bundesbank is the case that proves it: display_default: false, so it
    # is nobody's default, and yet "EUR (BMF)" sits in the dropdown of every
    # euro report. Treating "not a default" as "not wanted" left it unfetched,
    # and choosing it produced a report with no rates.
    #
    # Needed whatever countries exist, including none: a report has to convert
    # before any tax rule is involved.
    def display_source_keys
      Array(CurrencyConfig.available).flat_map { |currency| sources_for_display(currency) }
                                     .push(display_fallback).compact.uniq
    end

    # The source used when the display currency is the base of no source at all
    # — a CHF or USD report cross-rates through the euro. Declared in the file
    # rather than hardcoded, so the last source name leaves Ruby.
    def display_fallback
      @display_fallback ||= config.find { |_k, c| c["display_fallback"] }&.first
    end

    # What the user sees. Never the internal key — "ESTV", not "estv_monthly".
    def label_for(source)
      config.dig(source.to_s, "label").presence || source.to_s.upcase
    end

    # The label for tight spaces — the report's currency dropdown, where "EUR
    # (Bundesbank)" does not fit. Falls back to the full label, so a source only
    # declares one when it needs it.
    def short_label_for(source)
      config.dig(source.to_s, "short_label").presence || label_for(source)
    end

    # Every source that can produce figures in this display currency: those
    # whose BASE is the currency, then the cross-rate fallback. This is what
    # lets a report be read at any series actually published in that currency —
    # EUR at the ECB or the BMF. Tier 1, and it names no country.
    #
    # ONLY SOURCES PUBLISHED IN THE CURRENCY. Ending with the cross-rate
    # fallback for every currency offered "GBP (ECB)" and "CHF (ECB)" — figures
    # neither institution has ever published, reachable only by inverting the
    # euro series. Naming a publisher who did not publish it is what made the
    # option misleading.
    #
    # The cost is deliberate and falls on CHF: ESTV is the only franc series and
    # it holds one month of history, so a franc report of any older period has
    # no rate at all rather than a euro cross-rate wearing ESTV's name. That is
    # the honest answer, and the app already has a way to say it — the converted
    # column comes out empty and the flash offers to add the rate by hand.
    #
    # DAILY SOURCES ARE NOT OFFERED HERE, and that is a decision. A daily series
    # exists for tax compliance, not as a way of looking at a report, and
    # offering it would be quietly wrong: the trial balance and the profit and
    # loss aggregate by MONTH in SQL, so the day is gone before any translator
    # sees it and every figure in a month would convert at one arbitrary day's
    # rate. Grouping those by day instead is possible and deliberately not done
    # — a management report has no need of day-level rates. A SUBMISSION does
    # get day accuracy, in Reports::TaxCategoryTotals#bucket.
    def sources_for_display(currency)
      code   = currency.to_s.upcase
      direct = config.select { |_k, c| c["base"] == code }.keys.reject { |s| daily?(s) }

      # No source publishes in this currency, so a cross-rate is the only thing
      # there is — exactly what display_fallback is for, and the only case it is
      # for.
      #
      # The cross-rate is not a choice a reader makes: it is what happens when
      # the published series cannot reach the period, decided per report by
      # ExchangeRate.source_for_span and shown as "CHF via ECB" in the select
      # once it has happened.
      return [ display_fallback ].compact if direct.empty?

      ([ display_source_for(code) ] + direct).compact.uniq
    end

    # Is this source merely being cross-rated into that currency, rather than
    # published in it? What separates "EUR (ECB)", which the ECB publishes, from
    # "CHF via ECB", which is its euro series inverted.
    def cross_rate?(currency, source)
      return false if source.blank?

      config.dig(source.to_s, "base") != currency.to_s.upcase
    end

    # [[label, value], ...] for the report's converted-column dropdown, where
    # a value is "CURRENCY:source" — see Reports::DisplayChoice.
    def display_options(currencies)
      Array(currencies).flat_map do |currency|
        sources_for_display(currency).map do |source|
          [ "#{currency} (#{short_label_for(source)})", "#{currency}:#{source}" ]
        end
      end
    end

    # The one value #daily? checks a source's "frequency" config key against.
    # Absence, or any other value, means monthly — there is no separate MONTHLY
    # constant, since nothing compares against it.
    DAILY = "daily"

    # A day at a time. True of most national central banks, and of the ECB's own
    # reference rates, which this app has always fetched and then collapsed to
    # one figure a month.
    def daily?(source_or_config)
      cfg = source_or_config.is_a?(Hash) ? source_or_config : config[source_or_config.to_s]
      cfg && cfg["frequency"].to_s == DAILY
    end

    # THE FETCH UNIT IS A MONTH FOR EVERY SOURCE, daily ones included, and that
    # is deliberate. One request to a daily feed's history file returns every
    # published day in the period it covers, so "fetch July" means "store July's
    # days" — the only shape the feeds actually support. `frequency` decides
    # what is IN a month's fetch, never how the months are counted.

    # What the number IS, which "frequency" does not say: a month-end spot
    # rate and a monthly average are both monthly and are different figures.
    def semantics_for(source)
      config.dig(source.to_s, "semantics")
    end

    # The fetch control is built by Rates::FetchOptions, which names each feed
    # by the AUTHORITY that accepts it — a question about tax rules, so it
    # cannot live in this file, which is tier 1 and reads no country. `manual`
    # is not offered: it is not a feed, and a typed rate is always manual.

    # True when the figure is published BEFORE the period it covers. HMRC's
    # monthly rate goes out on the penultimate Thursday of the PRECEDING month
    # and is fixed for the month it names, so it exists before that month
    # begins. An average or a spot rate cannot, by definition.
    def published_in_advance?(source)
      semantics_for(source) == "month_fixed"
    end

    # Which day of a month to ask for. A month-end spot rate is fetched on the
    # last day; everything else is keyed to the month itself.
    def fetch_date_for(source, month_start)
      return month_start.end_of_month if semantics_for(source) == "month_end_spot"

      month_start.beginning_of_month
    end

    # DOES THIS PERIOD EXIST YET, for this source?
    #
    # Sources become available at opposite ends of a month. HMRC's rate is FIXED
    # FOR the month ahead and exists before it begins; an average or a month-end
    # spot is only computed once the month is over.
    #
    # AND A THIRD CASE: ESTV serves a ROLLING CURRENT MONTH, its window running
    # the 25th to the 24th, so it has this month's figure now. Treating it as
    # "an average, therefore not until month end" refused the one month it had.
    # backfillable? separates them — a source that cannot reach the past has
    # nothing BUT the current month.
    #
    # Lives here, not in the controller, because a JOB needs the same answer:
    # CurrencyCoverageJob asked every source for the current month and got
    # nothing from the ECB or the Bundesbank, whose current month does not exist
    # yet, silently seeding no rates for exactly the two sources a euro report
    # depends on.
    def period_available?(source, month_start)
      # A DAILY source's month is available the moment the month starts, and
      # stays worth re-fetching until the month ends. The rule below is about a
      # figure describing a whole month — an average or a closing rate — which
      # cannot exist until the month is over. A daily source publishes no such
      # figure, so the general rule would refuse the current month outright: the
      # one month a daily feed most reliably has.
      return month_start <= Date.current if daily?(source)

      awaits_month_end = !published_in_advance?(source) && backfillable?(source)

      if awaits_month_end
        month_start.end_of_month <= Date.current
      else
        month_start <= Date.current.end_of_month
      end
    end

    # The most recent period this source actually has — this month where the
    # figure already exists, last month where it does not. What to ask for when
    # you want whatever is newest, rather than guessing at the calendar.
    def latest_available_period(source, on: Date.current)
      this_month = on.beginning_of_month
      period_available?(source, this_month) ? this_month : this_month.prev_month
    end

    # Can this feed serve a period that has already passed?
    #
    # Three routes count: a dedicated history file, an archive, or a url with
    # %{...} in it, meaning the period is a request parameter. ESTV has none of
    # the three — it serves the current month and ignores ?d=, ?month= and
    # ?date= alike — so its history can never be filled and asking for it would
    # fail every night, forever.
    #
    # This is a fact about the FEED, and that is the point. Skipping any source
    # that was not a report's display default swept up the Bundesbank along with
    # ESTV, for a reason that was only ever true of ESTV.
    def backfillable?(source)
      c = fetch_config(source) or return false

      c["history_url"].present? || c["archive_url"].present? || c["url"].to_s.include?("%{")
    end

    def fetch_config(source)
      config[source.to_s]
    end

    def reload!
      @config = @bases = @display_sources = @display_fallback = nil
    end

    def config
      @config ||= YAML.safe_load_file(PATH) || {}
    end
  end
end
