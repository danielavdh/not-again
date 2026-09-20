# frozen_string_literal: true

require "csv"

module Rates
  # The Deutsche Bundesbank's monthly averages of the ECB daily reference rates
  # — the figures the BMF publishes as the binding conversion rates for German
  # VAT under §16(6) UStG.
  #
  # The BMF's own CSV sits behind bot management and cannot be fetched. The
  # Bundesbank is not a substitute for it, it is the SOURCE of it: it sends the
  # BMF these averages on the first working day of the following month.
  #
  # The layout is WIDE — one column per series, not one row per currency:
  #
  # "",BBEX3.M.CHF.EUR.BB.AC.A01,BBEX3.M.CHF.EUR.BB.AC.A01_FLAGS
  # "",Euro foreign exchange reference rate of the ECB / EUR 1 = CHF ...,
  # Decimals,4,
  # unit multiplier,One,
  # 2026-06,0.9224,
  #
  # A metadata block first, then data rows keyed by period. With a wildcard in
  # the series key (M..EUR.BB.AC.A01) one request returns 47 currencies as 47
  # column pairs.
  class BundesbankCsvParser
    # BBEX3.M.<CURRENCY>.EUR.BB.AC.A01 — the third segment is the currency.
    SERIES = /\ABBEX3\.M\.([A-Z]{3})\./
    PERIOD = /\A\d{4}-\d{2}\z/

    def self.parse(body, requested_date: nil)
      # liberal_parsing: the metadata block above the data carries free text
      # with quotes and commas in it, and one malformed comment must not cost
      # the whole response.
      rows = CSV.parse(body, liberal_parsing: true)
      return nil if rows.empty?

      columns = currency_columns(rows.first)
      return nil if columns.empty?

      # Several months can come back in one response. Take the one asked for,
      # and the latest otherwise — never silently a different month.
      wanted = requested_date && requested_date.strftime("%Y-%m")
      data   = rows.select { |r| r.first.to_s.strip.match?(PERIOD) }
      row    = (wanted && data.find { |r| r.first.to_s.strip == wanted }) || data.last

      # :no_data_yet, NOT nil. The structure was recognised and simply holds
      # nothing for that period — the Bundesbank publishes a month's average
      # after the month ends, so asking on the 18th is normal. nil is reserved
      # for "I did not recognise this at all", which is the alarm worth waking
      # someone for.
      return :no_data_yet unless row

      rates = columns.each_with_object({}) do |(index, currency), h|
        value = row[index].to_s.strip.to_f
        h[currency] = value if value.positive?
      end
      return nil if rates.empty?

      month = Date.strptime(row.first.to_s.strip, "%Y-%m")
      { rates: rates, valid_from: month, valid_to: month.end_of_month }
    end

    # index => currency, skipping the _FLAGS column that follows each series.
    def self.currency_columns(header)
      header.each_with_index.each_with_object({}) do |(cell, index), h|
        next if cell.to_s.end_with?("_FLAGS")

        match = SERIES.match(cell.to_s)
        h[index] = match[1] if match
      end
    end
  end
end
