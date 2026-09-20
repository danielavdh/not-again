# frozen_string_literal: true

require "csv"

module Rates
  # HMRC's own monthly rates, from the Trade Tariff service.
  #
  # Country/Territories,Currency,Currency Code,Currency Units per £1,Start
  # date,End date
  # Abu Dhabi,Dirham,AED,4.9091,01/08/2026,31/08/2026
  class HmrcCsvParser
    CODE   = "Currency Code"
    START  = "Start date"
    FINISH = "End date"
    # Matched by prefix, not by the exact header: the real one is "Currency
    # Units per £1", and depending on a pound sign surviving an HTTP round trip
    # is how this failed the first time.
    RATE_PREFIX = "Currency Units per"

    def self.parse(body, requested_date: nil)
      rows = CSV.parse(body, headers: true)
      return nil if rows.headers.blank? || rows.headers.compact.exclude?(CODE)

      rate_header = rows.headers.compact.find { |h| h.start_with?(RATE_PREFIX) }
      return nil unless rate_header

      rates = {}
      rows.each do |row|
        code = row[CODE].to_s.strip.upcase
        rate = row[rate_header].to_s.strip.to_f
        next if code.empty? || !rate.positive?

        # Rows are per COUNTRY, so every country using the US dollar gets its
        # own line with the same rate. First wins: they agree by construction,
        # and disagreeing would be HMRC's problem to explain, not ours to
        # average away.
        rates[code] ||= rate
      end
      return nil if rates.empty?

      span = period_from(rows.first)
      return nil unless span

      { rates: rates, valid_from: span.first, valid_to: span.last }
    end

    # The feed DECLARES its own validity span, in every row, so valid_from and
    # valid_to are read, never inferred.
    #
    # Refusing when the dates are missing, rather than falling back to the
    # requested month, is deliberate: asking for July on 1 August once stored
    # August's rates labelled July, and every GBP figure for that month was
    # quietly wrong.
    def self.period_from(row)
      from = parse_uk_date(row[START])
      to   = parse_uk_date(row[FINISH])
      return nil unless from && to && to >= from

      [ from, to ]
    end

    # DD/MM/YYYY. Date.parse would read 01/08/2026 as 8 January under some
    # locales, so the format is stated rather than guessed.
    def self.parse_uk_date(value)
      Date.strptime(value.to_s.strip, "%d/%m/%Y")
    rescue ArgumentError, TypeError
      nil
    end
  end
end
