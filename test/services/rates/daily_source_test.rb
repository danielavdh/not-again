# frozen_string_literal: true
require "test_helper"

# A DAILY rate source, end to end.
#
# Every source shipped before this one was monthly, and `frequency:` was
# declared on all four and read by nothing. Not merely untidy: the Netherlands
# and Spain both key VAT to the rate at the moment of the taxable event, against
# the ECB's DAILY reference rate. Germany naming a monthly average is the
# exception in Europe, not the rule.
#
# The feed is one the app has always fetched. `ecb` keeps the last published day
# of a month and lets it stand for the month; `ecb_daily` keeps every day. Two
# series, two numbers, and they must not be merged.
class Rates::DailySourceTest < ActiveSupport::TestCase
  # A real ECB response in miniature: three published days, with a weekend
  # between two of them. The gap is the point — no publisher quotes on a
  # Saturday, so a daily series has holes by nature rather than by fault.
  FEED = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"
                     xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
      <Cube>
        <Cube time="2026-08-11">
          <Cube currency="USD" rate="1.1700"/>
          <Cube currency="GBP" rate="0.8570"/>
        </Cube>
        <Cube time="2026-08-10">
          <Cube currency="USD" rate="1.1690"/>
          <Cube currency="GBP" rate="0.8560"/>
        </Cube>
        <Cube time="2026-08-07">
          <Cube currency="USD" rate="1.1680"/>
          <Cube currency="GBP" rate="0.8550"/>
        </Cube>
        <Cube time="2026-07-31">
          <Cube currency="USD" rate="1.1600"/>
          <Cube currency="GBP" rate="0.8500"/>
        </Cube>
      </Cube>
    </gesmes:Envelope>
  XML

  # --- the parser ----------------------------------------------------------

  test "it returns one period per published day, each a single-day span" do
    periods = Rates::EcbDailyXmlParser.parse(FEED, requested_date: Date.new(2026, 8, 1))

    assert_kind_of Array, periods, "a daily feed answers with MANY periods, not one"
    assert_equal 3, periods.size, "August has three published days in this feed"
    assert periods.all? { |p| p[:valid_from] == p[:valid_to] },
           "a day stands for itself — a span of one day, not of a month"
  end

  # The whole reason the many-period form exists. The ECB's daily file holds
  # TODAY alone, so a month of days can only come from the 90-day file or the
  # archive — and both hand back every day at once.
  test "a month is filtered out of a file holding several" do
    periods = Rates::EcbDailyXmlParser.parse(FEED, requested_date: Date.new(2026, 8, 1))
    assert_equal [ Date.new(2026, 8, 7), Date.new(2026, 8, 10), Date.new(2026, 8, 11) ],
                 periods.map { |p| p[:valid_from] }.sort,
                 "31 July is in the file and must not be stored as August"
  end

  test "a recognisable file that does not reach the month says so, rather than failing" do
    assert_equal :no_data_yet,
                 Rates::EcbDailyXmlParser.parse(FEED, requested_date: Date.new(2020, 1, 1)),
                 "the fetcher must try a wider file, not report a broken feed"
  end

  test "a response that is not the feed at all is refused" do
    assert_nil Rates::EcbDailyXmlParser.parse("<html><body>Down for maintenance</body></html>",
                                                   requested_date: Date.new(2026, 8, 1))
  end

  # One bad row must not cost the other 249 — a year file is a lot to lose to a
  # single malformed attribute.
  test "a malformed day is skipped and the rest survive" do
    broken = FEED.sub('time="2026-08-10"', 'time="not-a-date"')
    periods = Rates::EcbDailyXmlParser.parse(broken, requested_date: Date.new(2026, 8, 1))
    assert_equal 2, periods.size
  end

  # --- storing -------------------------------------------------------------

  test "many periods from one response become many spans" do
    stub_fetch(FEED) do
      result = Rates::Fetcher.fetch_and_store("ecb_daily", Date.new(2026, 8, 1))
      assert result[:success]
      assert_equal 3, result[:periods]
    end

    rows = ExchangeRate.where(source: "ecb_daily")
    assert_equal 3, rows.distinct.count(:valid_from)
    assert rows.all? { |r| r.valid_from == r.valid_to }
  end

  # The two series are different NUMBERS, not two views of one. Storing only the
  # daily series would make a monthly report convert each posting at its own
  # day's rate rather than the month's closing rate — more precise, and it would
  # silently change every figure in every report already saved.
  test "the daily series does not collide with the monthly one" do
    monthly = ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD", source: "ecb", rate: 1.16,
      effective_date: Date.new(2026, 8, 1),
      valid_from: Date.new(2026, 8, 1), valid_to: Date.new(2026, 8, 31)
    )

    stub_fetch(FEED) { Rates::Fetcher.fetch_and_store("ecb_daily", Date.new(2026, 8, 1)) }

    assert_equal 1.16, monthly.reload.rate, "the month's own figure is untouched"
    assert_equal 3, ExchangeRate.where(source: "ecb_daily", to_currency: "USD").count,
                 "overlapping spans are legal ACROSS sources — that is what source is for"
  end

  # --- which files a daily source may use ----------------------------------

  # The trap this prevents: the ECB's ordinary url holds ONE day. Ask it for
  # July, store the single span it returns, and every other day of July silently
  # has no rate — a gap that looks exactly like a completed fetch.
  test "a daily source reaches for a multi-day file even for the current month" do
    urls = Rates::Fetcher.send(
      :candidate_urls, RateSourceConfig.fetch_config("ecb_daily"), Date.current
    )
    assert_match(/hist-90d/, urls.first,
                 "the current month must come from a file that holds more than today")
  end

  test "a monthly source still asks its ordinary url for the current month" do
    urls = Rates::Fetcher.send(
      :candidate_urls, RateSourceConfig.fetch_config("ecb"), Date.current
    )
    assert_equal RateSourceConfig.fetch_config("ecb")["url"], urls.first
  end

  # --- when a period is fetchable ------------------------------------------

  # A month-average or a closing rate cannot exist until the month is over. A
  # daily source publishes no such figure — it publishes today, today — so the
  # general rule would refuse the one month it most reliably has.
  test "a daily source's current month is available; a monthly source's is not" do
    this_month = Date.current.beginning_of_month
    assert RateSourceConfig.period_available?("ecb_daily", this_month)
    assert_not RateSourceConfig.period_available?("ecb", this_month)
  end

  test "no source offers a month that has not started" do
    assert_not RateSourceConfig.period_available?("ecb_daily", Date.current.next_month.beginning_of_month)
  end

  private

  # Every candidate url returns the same document, which is what the real
  # 90-day and archive files do for an overlapping period.
  def stub_fetch(body)
    Rates::Fetcher.stub(:fetch_url, body) { yield }
  end
end
