# frozen_string_literal: true

module Rates
  # The Swiss Federal Tax Administration's monthly average rates for VAT, served
  # by the BAZG explicitly for accounting software.
  #
  # <monatsmittelkurs>
  # <monat>2026-08</monat>
  # <devise code="eur"><waehrung>1 EUR</waehrung><kurs>0.9328</kurs></devise>
  # <devise code="dkk"><waehrung>100 DKK</waehrung><kurs>12.4792</kurs></devise>
  #
  # Two things need undoing before the rest of the app sees a number, and both
  # are invisible in the raw feed:
  #
  # 1. WEAK CURRENCIES ARE QUOTED PER 100 UNITS. "100 DKK" costs 12.4792 francs,
  # so one krone is 0.124792. Miss it and every Danish figure is out by a factor
  # of a hundred, looking entirely plausible.
  # 2. The DIRECTION is inverted relative to how rates are stored. ESTV says
  # what one euro costs in francs; the table holds units of the other currency
  # per one unit of the base, and the base here is CHF.
  #
  # Both collapse into multiplier / kurs, and nothing downstream ever learns
  # that this feed is unusual.
  #
  # CURRENT MONTH ONLY: <monat> ignores ?d=, ?month= and ?date=. Swiss history
  # cannot be backfilled from here — it accumulates month by month, or is
  # entered by hand.
  class EstvXmlParser
    def self.parse(body, requested_date: nil)
      doc = Nokogiri::XML(body)
      doc.remove_namespaces!

      month = doc.at_xpath("//monat")&.text.to_s.strip
      # The feed's own period, never the caller's — same rule as HMRC, and
      # doubly so here, where asking for June returns August without saying so.
      return nil unless month.match?(/\A\d{4}-\d{2}\z/)

      start_of_month = Date.strptime(month, "%Y-%m")

      rates = doc.xpath("//devise").each_with_object({}) do |devise, h|
        code = devise["code"].to_s.strip.upcase
        kurs = devise.at_xpath("kurs")&.text.to_s.strip.to_f
        next if code.empty? || !kurs.positive?

        multiplier = quote_multiplier(devise.at_xpath("waehrung")&.text)
        h[code] = multiplier / kurs
      end
      return nil if rates.empty?

      { rates: rates,
        valid_from: start_of_month,
        valid_to:   start_of_month.end_of_month }
    end

    # "1 EUR" => 1, "100 DKK" => 100. Defaults to 1 rather than 0 or nil: a
    # missing multiplier should leave the rate unchanged, not destroy it.
    def self.quote_multiplier(waehrung)
      value = waehrung.to_s.strip[/\A\d+/].to_i
      value.positive? ? value : 1
    end
  end
end
