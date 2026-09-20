# frozen_string_literal: true

require "test_helper"

class ExchangeRateTest < ActiveSupport::TestCase
  test "valid exchange rate" do
    rate = ExchangeRate.new(
      from_currency: "GBP",
      to_currency: "EUR",
      rate: 1.15,
      effective_date: Date.current
    )
    assert rate.valid?, rate.errors.full_messages.join(", ")
  end

  test "invalid without from_currency" do
    rate = ExchangeRate.new(to_currency: "EUR", rate: 1.15)
    assert_not rate.valid?
  end

  test "invalid without to_currency" do
    rate = ExchangeRate.new(from_currency: "GBP", rate: 1.15)
    assert_not rate.valid?
  end

  test "invalid without rate" do
    rate = ExchangeRate.new(from_currency: "GBP", to_currency: "EUR")
    assert_not rate.valid?
  end

  test "rate must be positive" do
    rate = ExchangeRate.new(
      from_currency: "GBP",
      to_currency: "EUR",
      rate: -1.0
    )
    assert_not rate.valid?
  end
end
