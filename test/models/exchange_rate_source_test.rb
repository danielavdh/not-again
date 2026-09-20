# frozen_string_literal: true
require "test_helper"

# Characterisation tests for the rate-source rule, written before it was
# extracted from seven copies of `to_currency == 'GBP' ? 'hmrc' : 'ecb'`. They
# assert today's answers exactly, so a refactor cannot change behaviour quietly
# and adding a third source has to declare itself here rather than drift.
class ExchangeRateSourceTest < ActiveSupport::TestCase
  test "sterling reads HMRC, because HMRC publishes against GBP" do
    assert_equal "hmrc", ExchangeRate.source_for("GBP")
  end

  test "euro reads the ECB, because the ECB publishes against EUR" do
    assert_equal "ecb", ExchangeRate.source_for("EUR")
  end

  # CHF reads ESTV, decided per report by ExchangeRate.source_for_span: all-or-
  # nothing, with the select showing "CHF via ECB" whenever the fallback fired.
  #
  # That fallback is what makes it safe. ESTV serves the current month only, so
  # it holds nothing before August 2026 — and when ESTV was simply made CHF's
  # source with no fallback, every historical Swiss report broke: the ECB held
  # those months and was no longer consulted, so a March 2026 report raised for
  # a rate sitting in the database.
  test "Swiss francs prefer the Swiss series" do
    assert_equal "estv", ExchangeRate.source_for("CHF")
  end

  test "a franc report falls back whole when ESTV cannot reach the period" do
    span = { to_currency: "CHF", from_currencies: [ "EUR" ] }
    assert_equal "ecb",
                 ExchangeRate.source_for_span("CHF", **span.except(:to_currency),
                                              from: Date.new(2020, 1, 1), to: Date.new(2020, 12, 31)),
                 "no ESTV that far back, so the whole report cross-rates"
  end

  # The lesson generalised: a source that cannot serve the periods people
  # actually report on must not be the default for its own base currency.
  test "a display default must be able to cover more than the current month" do
    RateSourceConfig.display_sources.each_value do |source|
      assert_not_equal "current_month_only", RateSourceConfig.fetch_config(source)["coverage"],
                       "#{source} cannot serve history and must not be a display default"
    end
  end

  # Currencies that are the base of no source still cross-rate from the ECB.
  test "everything else falls back to the ECB, cross-rated" do
    assert_equal "ecb", ExchangeRate.source_for("USD")
    assert_equal "ecb", ExchangeRate.source_for("UAH")
  end

  test "case and symbol type do not matter" do
    assert_equal "hmrc", ExchangeRate.source_for("gbp")
    assert_equal "hmrc", ExchangeRate.source_for(:GBP)
  end

  test "a missing display currency does not raise" do
    assert_equal "ecb", ExchangeRate.source_for(nil)
  end

  # Every source named as a display default must have a base currency recorded,
  # or cross-rating silently returns nothing. Read from
  # db/exchange_rate_sources.yml, so this is the guard a badly-written YAML
  # entry trips over.
  test "every display source has a cross-rate base" do
    RateSourceConfig.display_sources.each_value do |source|
      assert RateSourceConfig.base_for(source),
             "#{source} is a display source but declares no base currency"
    end
  end

  test "exactly one source is the display fallback" do
    fallbacks = RateSourceConfig.all.select { |s|
      RateSourceConfig.fetch_config(s)["display_fallback"]
    }
    assert_equal 1, fallbacks.size,
                 "expected one display_fallback, found #{fallbacks.inspect}"
    assert RateSourceConfig.base_for(fallbacks.first),
           "the fallback source must declare a base currency"
  end

  # A source declaring display_default for a base another already claims would
  # silently lose — first wins. Catch it in the file, not in a report.
  test "no two sources claim the same base as display default" do
    claimed = RateSourceConfig.all
      .select { |s| RateSourceConfig.fetch_config(s)["display_default"] }
      .map    { |s| RateSourceConfig.base_for(s) }
    assert_equal claimed.uniq, claimed,
                 "two sources claim the same base as display default: #{claimed.inspect}"
  end
end
