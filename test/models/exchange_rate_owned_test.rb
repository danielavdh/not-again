# frozen_string_literal: true
require "test_helper"

# A business may elect its own exchange rate where the law allows — Switzerland
# permits a group's internal rate, Hungary lets you pick a credit institution,
# Germany accepts a documented daily rate for a currency nobody publishes.
#
# "Enter it by hand" is only a real escape hatch because the lookup does NOT
# filter owned rows by source: a euro report reads `ecb`, so a `manual` row
# filtered by source could never be found.
class ExchangeRateOwnedTest < ActiveSupport::TestCase
  setup do
    @mine   = Entity.create!(code: "94", name: "Mine", active: true)
    @theirs = Entity.create!(code: "95", name: "Theirs", active: true)
    @month  = Date.new(2030, 4, 1)

    # The published series everyone shares.
    ExchangeRate.create!(from_currency: "EUR", to_currency: "SEK", source: "ecb",
                              rate: 10.0, effective_date: @month,
                              valid_from: @month, valid_to: @month.end_of_month)
  end

  def own_rate(entity, value, from: "EUR", to: "SEK", month: nil)
    month ||= @month
    ExchangeRate.create!(from_currency: from, to_currency: to, source: "manual",
                              rate: value, effective_date: month, entity_id: entity.id,
                              note: "board minute", valid_from: month, valid_to: month.end_of_month)
  end

  def convert(entity)
    ExchangeRate.translator("SEK", date: @month, entity: entity)
                     .translate(100, "EUR", on: @month + 10)
  end

  test "without an owned rate, the published series is used" do
    assert_equal 1_000, convert(@mine)
  end

  # Daniela's ruling 2026-08-19: "if an entity has a rate, that's the rate we
  # use whenever it is available."
  test "an entity's own rate wins over the published one" do
    own_rate(@mine, 12.0)
    assert_equal 1_200, convert(@mine)
  end

  # The leak this guards against. Owned rates are looked up WITHOUT a source
  # filter, so the published query must exclude owned rows explicitly — or one
  # business's elected rate would be applied to everyone's books.
  test "one entity's rate never reaches another's figures" do
    own_rate(@mine, 12.0)

    assert_equal 1_000, convert(@theirs), "another entity must still see the published rate"
    assert_equal 1_000, convert(nil),     "a view built from no single entity sees only the published series"
  end

  # Months the business has not entered fall back to the published series. Worth
  # pinning because it is what people get caught by: electing your own rate for
  # three months of a year converts the other nine at the published one, and
  # most authorities require the choice to be applied consistently.
  test "months without an owned rate fall back to the published series" do
    own_rate(@mine, 12.0)

    may = Date.new(2030, 5, 1)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "SEK", source: "ecb",
                              rate: 11.0, effective_date: may,
                              valid_from: may, valid_to: may.end_of_month)

    t = ExchangeRate.translator("SEK", date: may, entity: @mine)
    assert_equal 1_100, t.translate(100, "EUR", on: may + 5),
                 "May has no owned rate, so the published one applies"
  end

  # The case hand-entry exists for: a currency the published source does not
  # carry at all. The ECB has no hryvnia and never will.
  test "an owned rate supplies a currency the published source lacks" do
    own_rate(@mine, 45.0, from: "EUR", to: "UAH")

    t = ExchangeRate.translator("UAH", date: @month, entity: @mine)
    assert_equal 4_500, t.translate(100, "EUR", on: @month + 3)

    without = ExchangeRate.translator("UAH", date: @month, entity: @theirs)
    assert_raises(ExchangeRate::RateUnavailable) do
      without.translate(100, "EUR", on: @month + 3)
    end
  end
end
