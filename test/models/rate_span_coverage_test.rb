require "test_helper"

# One series for the whole report, or none of it.
#
# A converted column is only comparable with itself: three months read at ESTV
# and a fourth at the ECB is a total nobody can defend and a reader cannot see
# the seam in. So a series either reaches every month of the period, or the
# report cross-rates for all of it and says so.
#
# TIER 1 only — management information, bound by no authority. A submission is
# bound by its country's rule and never comes near this.
class RateSpanCoverageTest < ActiveSupport::TestCase
  JAN = Date.new(2027, 1, 1)

  setup do
    ExchangeRate.where(to_currency: "CHF").delete_all
  end

  def estv_for(*months)
    months.each do |m|
      ExchangeRate.create!(from_currency: "EUR", to_currency: "CHF", source: "estv",
                           rate: 0.95, effective_date: m, valid_from: m, valid_to: m.end_of_month)
    end
  end

  test "a series covering every month of the period is the one used" do
    estv_for(JAN, JAN >> 1)

    assert ExchangeRate.covers_span?(to_currency: "CHF", from_currencies: [ "EUR" ],
                                     source: "estv", from: JAN, to: (JAN >> 1).end_of_month)
    assert_equal "estv", span_source(JAN, (JAN >> 1).end_of_month)
  end

  # The case that matters: three months held, one missing. The report does not
  # use ESTV for three quarters of itself.
  test "one missing month costs the series the whole report" do
    estv_for(JAN, JAN >> 1, JAN >> 2)

    assert_not ExchangeRate.covers_span?(to_currency: "CHF", from_currencies: [ "EUR" ],
                                         source: "estv", from: JAN, to: (JAN >> 3).end_of_month)
    assert_equal "ecb", span_source(JAN, (JAN >> 3).end_of_month),
                 "a fourth uncovered month must move the whole report to the cross-rate"
  end

  # Coverage is per currency, not merely per month: a franc report of a business
  # holding both euros and sterling needs both legs for every month.
  test "a month covered for one currency but not another is not covered" do
    estv_for(JAN)

    assert_not ExchangeRate.covers_span?(to_currency: "CHF", from_currencies: %w[EUR GBP],
                                         source: "estv", from: JAN, to: JAN.end_of_month)
  end

  test "the display currency itself needs no rate" do
    assert ExchangeRate.covers_span?(to_currency: "CHF", from_currencies: [ "CHF" ],
                                     source: "estv", from: JAN, to: JAN.end_of_month),
           "converting francs to francs asks nothing of any series"
  end

  # A reader's own pick is honoured where it reaches and falls back where it
  # does not — choosing ESTV cannot conjure a month ESTV never published.
  test "an explicit choice falls back on the same rule" do
    estv_for(JAN)

    assert_equal "estv", span_source(JAN, JAN.end_of_month, preferred: "estv")
    assert_equal "ecb",  span_source(JAN, (JAN >> 2).end_of_month, preferred: "estv")
  end

  # Sterling has its own published series, so it is never offered the ECB —
  # the option named a figure the ECB has never published.
  test "only series published in the currency are offered" do
    assert_equal [ "hmrc" ], RateSourceConfig.sources_for_display("GBP")
    assert_equal [ "estv" ], RateSourceConfig.sources_for_display("CHF")
    assert_equal [ "ecb" ],  RateSourceConfig.sources_for_display("USD"),
                 "no source publishes in dollars, so the cross-rate is all there is"
  end

  test "a cross-rate is named as one" do
    assert RateSourceConfig.cross_rate?("CHF", "ecb")
    assert_not RateSourceConfig.cross_rate?("CHF", "estv")
    assert_not RateSourceConfig.cross_rate?("EUR", "ecb")
  end

  # HMRC publishes "units per £1" and stores GBP→EUR, so a sterling report
  # converting euros reads that row INVERTED and coverage has to be counted in
  # both directions. Counting one found no HMRC row at all, and every sterling
  # report silently fell back to the euro cross-rate.
  test "a series stored the other way round still counts as coverage" do
    ExchangeRate.where(from_currency: "GBP", to_currency: "SEK").delete_all
    m = Date.new(2027, 5, 1)
    ExchangeRate.create!(from_currency: "GBP", to_currency: "SEK", source: "hmrc",
                         rate: 13.2, effective_date: m, valid_from: m, valid_to: m.end_of_month)

    assert ExchangeRate.covers_span?(to_currency: "SEK", from_currencies: [ "GBP" ],
                                     source: "hmrc", from: m, to: m.end_of_month),
           "GBP→SEK must count as coverage for a SEK report converting sterling"
  end

  private

  def span_source(from, to, preferred: nil)
    ExchangeRate.source_for_span("CHF", from_currencies: [ "EUR" ],
                                 from: from, to: to, preferred: preferred)
  end
end
