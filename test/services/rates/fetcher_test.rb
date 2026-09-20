# frozen_string_literal: true
require "test_helper"

# The period comes from the FEED, never from the caller.
#
# HMRC's monthly rate is published on the penultimate Thursday of the PRECEDING
# month and is fixed for the month it names, so the feed declares its own
# period. Storing whatever date the caller asked for meant that asking for July
# on 1 August stored AUGUST's rates labelled July, and every GBP translation for
# that month used the wrong number. Nothing failed; the figures were simply
# wrong.
#
# The rule survived the move from a third-party JSON mirror to HMRC's own CSV on
# the Trade Tariff service — the CSV declares Start date and End date in every
# row.
class Rates::FetcherTest < ActiveSupport::TestCase
  # Real shape, verified against the live file. Note the per-COUNTRY rows: every
  # country using a currency gets its own line.
  AUGUST_CSV = <<~CSV
    Country/Territories,Currency,Currency Code,Currency Units per £1,Start date,End date
    Eurozone,Euro,EUR,1.1719,01/08/2026,31/08/2026
    Switzerland,Franc,CHF,1.0863,01/08/2026,31/08/2026
    United States of America,Dollar,USD,1.3421,01/08/2026,31/08/2026
    Ecuador,Dollar,USD,1.3421,01/08/2026,31/08/2026
  CSV

  test "stores under the period the feed declares, not the month asked for" do
    Rates::Fetcher.stub(:fetch_url, AUGUST_CSV) do
      result = Rates::Fetcher.fetch_and_store("hmrc", Date.new(2026, 7, 1))
      assert result[:success], result[:error]
      assert_equal Date.new(2026, 8, 1),  result[:valid_from]
      assert_equal Date.new(2026, 8, 31), result[:valid_to]
    end

    assert_nil ExchangeRate.find_by(source: "hmrc", from_currency: "GBP",
                                         to_currency: "EUR", valid_from: Date.new(2026, 7, 1)),
               "August's rates must never be filed under July"

    august = ExchangeRate.find_by(source: "hmrc", from_currency: "GBP",
                                       to_currency: "EUR", valid_from: Date.new(2026, 8, 1))
    assert_equal 1.1719, august.rate.to_f
    assert_equal Date.new(2026, 8, 31), august.valid_to,
                 "the span is read from the feed, not derived from the month"
  end

  test "a feed with no period is refused rather than guessed at" do
    undated = "Country/Territories,Currency,Currency Code,Currency Units per £1\nEurozone,Euro,EUR,1.2\n"

    Rates::Fetcher.stub(:fetch_url, undated) do
      result = Rates::Fetcher.fetch_and_store("hmrc", Date.new(2026, 7, 1))
      assert_equal false, result[:success]
    end

    assert_nil ExchangeRate.find_by(source: "hmrc", valid_from: Date.new(2026, 7, 1))
  end

  # The registry decides which parser and which base currency; the fetcher only
  # knows how to make a request and write a row.
  test "an undeclared source is refused, not guessed at" do
    result = Rates::Fetcher.fetch_and_store("bank_of_nowhere", Date.current)
    assert_equal false, result[:success]
    assert_match(/unknown source/, result[:error])
  end

  # HMRC publishes about 170 currencies. Storing them all would fill the table
  # with rates nobody can select.
  test "only currencies the app supports are stored" do
    Rates::Fetcher.stub(:fetch_url, AUGUST_CSV) do
      Rates::Fetcher.fetch_and_store("hmrc", Date.new(2026, 8, 1))
    end

    stored = ExchangeRate.where(source: "hmrc", valid_from: Date.new(2026, 8, 1))
                              .pluck(:to_currency).sort
    assert_equal CurrencyConfig.available.sort & %w[EUR CHF USD], stored,
                 "expected only supported currencies, got #{stored.inspect}"
  end

  # A8 (audit-2): the base currency itself was never checked against
  # CurrencyConfig.available — only the TARGET currencies were, so retiring
  # the currency a source publishes FROM did not stop that source at all.
  test "a retired base currency stops the whole source, not just its own row" do
    Currency.find_by(code: "GBP").update!(active: false)

    Rates::Fetcher.stub(:fetch_url, AUGUST_CSV) do
      result = Rates::Fetcher.fetch_and_store("hmrc", Date.new(2026, 8, 1))
      assert result[:success]
    end

    assert_empty ExchangeRate.where(source: "hmrc", valid_from: Date.new(2026, 8, 1)),
                 "GBP is the base HMRC publishes from; retiring it must stop the whole fetch"
  ensure
    Currency.find_by(code: "GBP").update!(active: true)
  end
end
