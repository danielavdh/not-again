# frozen_string_literal: true
require "test_helper"

class TaxCategoryTest < ActiveSupport::TestCase
  def valid_attrs(overrides = {})
    { country_code: "gb", scheme: "gb_self_employment", tax_year: 2026,
      key: "travel_costs", section: "expenses", position: 10 }.merge(overrides)
  end

  test "valid with required attributes" do
    assert TaxCategory.new(valid_attrs).valid?
  end

  test "country_code must be 2 lowercase letters" do
    refute TaxCategory.new(valid_attrs(country_code: "GB")).valid?
    refute TaxCategory.new(valid_attrs(country_code: "gbr")).valid?
    assert TaxCategory.new(valid_attrs(country_code: "gb")).valid?
  end

  test "key must be snake_case" do
    refute TaxCategory.new(valid_attrs(key: "Travel Costs")).valid?
    refute TaxCategory.new(valid_attrs(key: "travel-costs")).valid?
    assert TaxCategory.new(valid_attrs(key: "travel_costs")).valid?
  end

  # A tax box has one name: the one printed on its own form. Translating it
  # would send someone hunting the paper for a box that is not there.
  test "label is the form's own wording, never translated" do
    cat = TaxCategory.new(valid_attrs(label: "Umgelegte Kosten"))
    assert_equal "Umgelegte Kosten", cat.label
    assert_equal "Umgelegte Kosten", cat.label(:en)
    assert_equal "Umgelegte Kosten", cat.label(:de)
  end

  # A catalogue contributed without labels still reads in its own language,
  # because the key slugs are already native.
  test "label falls back to the key when the catalogue gives none" do
    assert_equal "Travel costs", TaxCategory.new(valid_attrs).label
  end

  test "display_name leads with the authority's reference" do
    assert_equal "15 — Turnover",
                 TaxCategory.new(valid_attrs(label: "Turnover", export_column: "15")).display_name
    assert_equal "Turnover",
                 TaxCategory.new(valid_attrs(label: "Turnover")).display_name
  end

  test "grouped_options carries the note to the browser on each option" do
    TaxCategory.create!(valid_attrs(key: "premises_running_costs", label: "Rent, rates, power",
                                    export_column: "21", notes: "Box 21 on SA103F"))
    groups = TaxCategory.grouped_options("gb_self_employment")
    option = groups.flat_map(&:last).find { |(_t, v, _a)| v == "gb_self_employment::premises_running_costs" }

    assert_equal "21 — Rent, rates, power", option[0]
    assert_equal "Box 21 on SA103F", option[2].dig(:data, :note)
  end

  test "grouped_options names the scheme only when several could be confused" do
    TaxCategory.create!(valid_attrs(label: "Turnover"))
    TaxCategory.create!(valid_attrs(scheme: "gb_property", key: "rent_income",
                                    section: "income", label: "Rent"))

    single = TaxCategory.grouped_options("gb_self_employment").flat_map(&:last).map(&:first)
    assert single.none? { |text| text.start_with?("[") }

    both = TaxCategory.grouped_options(%w[gb_self_employment gb_property]).flat_map(&:last).map(&:first)
    assert both.all? { |text| text.start_with?("[") }
  end

  test "grouped_options is empty without schemes or a catalogue" do
    assert_equal [], TaxCategory.grouped_options([])
    assert_equal [], TaxCategory.grouped_options(nil)
    assert_equal [], TaxCategory.grouped_options("no_such_scheme")
  end

  test "key unique per (country, scheme, year)" do
    TaxCategory.create!(valid_attrs)
    dup = TaxCategory.new(valid_attrs)
    refute dup.valid?
    assert dup.errors[:key].any?
  end

  test "same key allowed in different year" do
    TaxCategory.create!(valid_attrs(tax_year: 2025))
    assert TaxCategory.new(valid_attrs(tax_year: 2026)).valid?
  end

  test "resolve returns the catalogue row" do
    tc = TaxCategory.create!(valid_attrs)
    assert_equal tc, TaxCategory.resolve(country_code: "gb", scheme: "gb_self_employment",
                                         year: 2026, key: "travel_costs")
  end

  test "resolve returns nil when any arg blank" do
    assert_nil TaxCategory.resolve(country_code: "gb", scheme: "gb_self_employment",
                                   year: 2026, key: nil)
  end

  test "resolve falls back to newest prior year when requested year missing" do
    TaxCategory.create!(valid_attrs(tax_year: 2026))
    tc = TaxCategory.resolve(country_code: "gb", scheme: "gb_self_employment",
                             year: 2029, key: "travel_costs")
    assert tc
    assert_equal 2026, tc.tax_year
  end

  test "resolve picks the newest prior year when multiple exist" do
    TaxCategory.create!(valid_attrs(tax_year: 2024))
    TaxCategory.create!(valid_attrs(tax_year: 2026))
    tc = TaxCategory.resolve(country_code: "gb", scheme: "gb_self_employment",
                             year: 2028, key: "travel_costs")
    assert_equal 2026, tc.tax_year
  end

  test "resolve returns nil when only later years exist" do
    TaxCategory.create!(valid_attrs(tax_year: 2026))
    assert_nil TaxCategory.resolve(country_code: "gb", scheme: "gb_self_employment",
                                   year: 2024, key: "travel_costs")
  end
end
