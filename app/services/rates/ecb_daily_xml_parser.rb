# frozen_string_literal: true

module Rates
  # The ECB's euro foreign exchange reference rates, kept as ONE SPAN PER DAY.
  #
  # <Cube time="2026-08-18">
  # <Cube currency="USD" rate="1.1485"/>
  #
  # The same document Rates::EcbXmlParser reads. The difference is what is kept,
  # and the two are genuinely different NUMBERS rather than two views of one:
  #
  # ecb        the last published day of a month, standing for the whole month
  # (semantics: month_end_spot). What every report reads.
  # ecb_daily  each published day, standing for itself (semantics: daily_spot).
  # What a Dutch or Spanish VAT return needs.
  #
  # THEY MUST NOT BE MERGED. Storing only the daily series and letting a monthly
  # report pick a day out of it would convert each posting at its own day's rate
  # instead of the month's closing rate — more precise, and it would silently
  # change the figures in every report already saved. Two series, two source
  # keys, and the exclusion constraint keeps their spans apart.
  #
  # The Netherlands and Spain both key VAT to the rate at the moment of the
  # taxable event, against the ECB's daily reference rate; Germany is the
  # outlier in naming a monthly average. Nothing fetches this source unless a
  # country's rule in db/exchange_rate_rules.yml names it.
  class EcbDailyXmlParser
    # An ARRAY of periods, one per published day — the many-period form of the
    # parser contract. Necessary rather than convenient: the ECB's daily file
    # holds today alone, so a month of days can only come from the 90-day file
    # or the archive, and both return every day at once.
    #
    # Returns :no_data_yet when the document is a recognisable ECB file that
    # simply does not reach the requested month, so the fetcher tries a wider
    # one instead of reporting a broken feed.
    def self.parse(body, requested_date: nil)
      doc = Nokogiri::XML(body)
      doc.remove_namespaces!

      days = doc.xpath("//Cube[@time]")
      return nil if days.empty?

      wanted = requested_date && (requested_date.beginning_of_month..requested_date.end_of_month)

      periods = days.filter_map { |day| period_for(day, wanted) }
      return :no_data_yet if periods.empty?

      periods
    end

    # One day, one span: valid_from == valid_to. The span model was chosen for
    # exactly this — the lookup asks which span contains a date and never cares
    # how long the span is.
    def self.period_for(day, wanted)
      date = Date.parse(day["time"].to_s)
      return nil if wanted && !wanted.cover?(date)

      rates = day.xpath(".//Cube[@currency]").each_with_object({}) do |cube, h|
        rate = cube["rate"].to_f
        h[cube["currency"]] = rate if rate.positive?
      end
      return nil if rates.empty?

      { rates: rates, valid_from: date, valid_to: date }
    rescue ArgumentError, TypeError
      # A malformed `time` on one day must not cost the other 249.
      nil
    end
    private_class_method :period_for
  end
end
