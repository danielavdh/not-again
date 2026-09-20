# frozen_string_literal: true

module Rates
  # The ECB's euro foreign exchange reference rates.
  #
  # <Cube time="2026-08-18">
  # <Cube currency="USD" rate="1.1485"/>
  #
  # The same shape serves eurofxref-daily.xml (one <Cube time>) and eurofxref-
  # hist.xml (one per day, back to 1999). This parser reads ONE day; a
  # historical backfill iterates.
  #
  # Read `time`, never just //Cube[@currency]: on the daily file ignoring it is
  # harmless, but on the historical file it flattens every day since 1999 into
  # one undated heap.
  class EcbXmlParser
    # Every parser answers the same question — what rates, over what span — so
    # the fetcher never learns which feed it is talking to.
    #
    # The span is the MONTH containing the published day, not the day itself.
    # That is what semantics: month_end_spot means: the ECB is fetched once, at
    # month end, and that figure stands for the month. A daily ECB series is a
    # separate source declaring one-day spans.
    def self.parse(body, requested_date:)
      doc = Nokogiri::XML(body)
      doc.remove_namespaces!

      days = doc.xpath("//Cube[@time]")
      day  = pick_day(days, requested_date)

      # :no_data_yet, not nil — the file was recognised and simply does not
      # reach that month. The daily file holds one day; the archive reaches back
      # to 1999 but stops at today.
      return :no_data_yet if days.any? && day.nil?

      # Prefer the feed's own date over the caller's — same reasoning as HMRC.
      # Falls back to the requested date for a feed that omits it.
      date = day && day["time"].present? ? Date.parse(day["time"]) : requested_date
      return nil unless date

      scope = day || doc
      rates = scope.xpath(".//Cube[@currency]").each_with_object({}) do |cube, h|
        rate = cube["rate"].to_f
        h[cube["currency"]] = rate if rate.positive?
      end
      return nil if rates.empty?

      { rates: rates,
        valid_from: date.beginning_of_month,
        valid_to:   date.end_of_month }
    end

    # The LAST published day within the requested month.
    #
    # semantics: month_end_spot means a month's figure is its closing rate, so
    # reading the archive has to behave exactly as the daily fetch does when it
    # runs on the 31st — anything else would make a backfilled month disagree
    # with one fetched live, for no visible reason.
    #
    # ECB files list days newest-first, so the first match is the latest. With
    # no month requested — the daily file, one entry — take that.
    def self.pick_day(days, requested_date)
      return days.first unless requested_date && days.size > 1

      month = requested_date.beginning_of_month..requested_date.end_of_month
      days.find do |d|
        parsed = Date.parse(d["time"]) rescue nil
        parsed && month.cover?(parsed)
      end
    end
  end
end
