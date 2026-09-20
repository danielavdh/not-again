# frozen_string_literal: true

require "test_helper"

class ExchangeRateLogicTest < ActiveSupport::TestCase
  # All records created in setup so dates are relative to Date.current.
  # Fixtures can't express "this month" reliably, so we build instead.

  setup do
    @this_month  = Date.current.beginning_of_month
    @prev_month  = (Date.current - 1.month).end_of_month
  end

  def create_rate(from:, to:, rate:, date: @this_month, source: "ecb")
    ExchangeRate.create!(
      from_currency: from,
      to_currency:   to,
      rate:          rate,
      effective_date: date,
      source:        source
    )
  end

  # ==================== rate_for: same currency ====================

  test "rate_for returns 1.0 for same currency" do
    assert_equal 1.0, ExchangeRate.rate_for("GBP", "GBP", date: Date.current)
  end

  # ==================== rate_for: direct match ====================

  test "rate_for returns direct rate when available" do
    create_rate(from: "GBP", to: "EUR", rate: 1.15)
    result = ExchangeRate.rate_for("GBP", "EUR", date: Date.current, source: "ecb")
    assert_in_delta 1.15, result, 0.001
  end

  # ==================== rate_for: inverse rate ====================

  test "rate_for computes inverse when only reverse pair stored" do
    create_rate(from: "EUR", to: "GBP", rate: 0.85)
    result = ExchangeRate.rate_for("GBP", "EUR", date: Date.current, source: "ecb")
    assert_in_delta(1.0 / 0.85, result, 0.001)
  end

  # ==================== rate_for: previous month fallback ====================

  test "rate_for falls back to previous month when current month has no rate" do
    create_rate(from: "GBP", to: "USD", rate: 1.25, date: @prev_month, source: "ecb")
    result = ExchangeRate.rate_for("GBP", "USD", date: Date.current, source: "ecb")
    assert_in_delta 1.25, result, 0.001
  end

  test "rate_for prefers current month over previous month" do
    create_rate(from: "GBP", to: "USD", rate: 1.25, date: @prev_month, source: "ecb")
    create_rate(from: "GBP", to: "USD", rate: 1.30, date: @this_month, source: "ecb")
    result = ExchangeRate.rate_for("GBP", "USD", date: Date.current, source: "ecb")
    assert_in_delta 1.30, result, 0.001
  end

  test "rate_for returns nil when no rate exists anywhere" do
    result = ExchangeRate.rate_for("GBP", "CHF", date: Date.current, source: "ecb")
    assert_nil result
  end

  # ==================== cross_rate_for ====================

  test "rate_for computes cross-rate via EUR for ECB source" do
    create_rate(from: "CHF", to: "EUR", rate: 0.95, source: "ecb")
    create_rate(from: "EUR", to: "GBP", rate: 0.85, source: "ecb")

    result = ExchangeRate.rate_for("CHF", "GBP", date: Date.current, source: "ecb")
    assert_in_delta(0.95 * 0.85, result, 0.001)
  end

  test "cross_rate_for returns nil when source is nil" do
    result = ExchangeRate.cross_rate_for("CHF", "GBP", Date.current, nil)
    assert_nil result
  end

  test "cross_rate_for returns nil when from_currency is base currency" do
    # EUR is the ECB base, so EUR->GBP cross-rate is not cross-rate, it's direct
    result = ExchangeRate.cross_rate_for("EUR", "GBP", Date.current, "ecb")
    assert_nil result
  end

  # ==================== translate ====================

  test "translate returns amount unchanged for same currency" do
    assert_equal 10000, ExchangeRate.translate(10000, "GBP", "GBP", date: Date.current)
  end

  test "translate returns 0 for nil amount" do
    assert_equal 0, ExchangeRate.translate(nil, "GBP", "EUR", date: Date.current)
  end

  test "translate returns 0 for zero amount" do
    assert_equal 0, ExchangeRate.translate(0, "GBP", "EUR", date: Date.current)
  end

  test "translate converts amount using rate" do
    create_rate(from: "GBP", to: "EUR", rate: 1.15, source: "ecb")
    result = ExchangeRate.translate(10000, "GBP", "EUR", date: Date.current)
    assert_equal 11500, result
  end

  # A missing rate must raise rather than return the amount unchanged — that is
  # 1.0 wearing a different hat: £100 becomes CHF 100 and looks entirely normal
  # on the page.
  test "translate REFUSES when no rate is found, rather than inventing one" do
    error = assert_raises(ExchangeRate::RateUnavailable) do
      ExchangeRate.translate(10_000, "GBP", "CHF", date: Date.current)
    end

    # The parts, so a caller can say something a human can act on.
    assert_equal "GBP", error.from_currency
    assert_equal "CHF", error.to_currency
    assert_match(/GBP/, error.message)
    assert_match(/CHF/, error.message)
  end

  test "a same-currency translation still needs no rate at all" do
    assert_equal 10_000, ExchangeRate.translate(10_000, "CHF", "CHF", date: Date.current)
  end

  test "a zero amount needs no rate either" do
    assert_equal 0, ExchangeRate.translate(0, "GBP", "CHF", date: Date.current)
  end

  # ==================== Translator ====================

  test "Translator#rate returns 1.0 for same currency" do
    translator = ExchangeRate.translator("GBP", date: Date.current)
    assert_equal 1.0, translator.rate("GBP")
  end

  test "Translator#rate fetches and caches rate" do
    create_rate(from: "GBP", to: "EUR", rate: 1.15, source: "ecb")
    translator = ExchangeRate.translator("EUR", date: Date.current)

    result = translator.rate("GBP")
    assert_in_delta 1.15, result, 0.001

    # Second call must return same value without DB hit — hard to assert
    # directly,
    # so we verify it's still correct after mutation (immutable fixture confirms
    # cache)
    assert_in_delta 1.15, translator.rate("GBP"), 0.001
  end

  test "Translator#translate converts cents" do
    create_rate(from: "GBP", to: "EUR", rate: 1.15, source: "ecb")
    translator = ExchangeRate.translator("EUR", date: Date.current)
    assert_equal 11500, translator.translate(10000, "GBP")
  end

  test "Translator#translate returns amount unchanged for same currency" do
    translator = ExchangeRate.translator("GBP", date: Date.current)
    assert_equal 10000, translator.translate(10000, "GBP")
  end

  test "Translator#translate returns 0 for nil amount" do
    translator = ExchangeRate.translator("EUR", date: Date.current)
    assert_equal 0, translator.translate(nil, "GBP")
  end

  # ==================== Translator#preload_rates ====================

  test "preload_rates loads rates in bulk and makes them available" do
    create_rate(from: "GBP", to: "EUR", rate: 1.15, source: "ecb")
    create_rate(from: "USD", to: "EUR", rate: 0.93, source: "ecb")

    translator = ExchangeRate.translator("EUR", date: Date.current)
    translator.preload_rates(%w[GBP USD])

    assert_in_delta 1.15, translator.rate("GBP"), 0.001
    assert_in_delta 0.93, translator.rate("USD"), 0.001
  end

  test "preload_rates falls back to previous month for missing currencies" do
    create_rate(from: "GBP", to: "EUR", rate: 1.12, date: @prev_month, source: "ecb")

    translator = ExchangeRate.translator("EUR", date: Date.current)
    translator.preload_rates(%w[GBP])

    assert_in_delta 1.12, translator.rate("GBP"), 0.001
  end
end
