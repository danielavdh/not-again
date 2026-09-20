# frozen_string_literal: true
require "test_helper"

# Which catalogue a report is built from.
#
# Without tax_year in the lookup, `where(scheme:).where(key:).index_by(&:key)`
# is unambiguous with a single year loaded, which is why nothing ever went
# wrong. With two, index_by keeps whichever row the database returned LAST for
# each key, and Postgres promises no order without ORDER BY — so the first 2027
# file would make every export and every submission quietly non-deterministic.
#
# These tests load a second year on purpose, which is the case that had no
# coverage at all.
class TaxCategoryYearTest < ActiveSupport::TestCase
  # A scheme of our own, so the real catalogues stay out of it.
  SCHEME = "yeartest_scheme"

  def category(year:, key:, export_column:)
    TaxCategory.create!(
      country_code: "gb", scheme: SCHEME, tax_year: year, key: key,
      label: "#{key} #{year}", export_column: export_column, section: "expenses", position: 1
    )
  end

  # --- which tax year a date belongs to ------------------------------------

  test "a British date on or after 6 April belongs to the NEXT numbered year" do
    # 2028/29 runs 6 Apr 2028 – 5 Apr 2029, and is numbered by the year it ends
    # in.
    assert_equal 2029, TaxCategory.tax_year_for(country_code: "gb", date: Date.new(2028, 4, 6))
    assert_equal 2029, TaxCategory.tax_year_for(country_code: "gb", date: Date.new(2028, 7, 5))
    assert_equal 2029, TaxCategory.tax_year_for(country_code: "gb", date: Date.new(2029, 4, 5))
  end

  test "a British date before 6 April still belongs to the year ending that April" do
    assert_equal 2028, TaxCategory.tax_year_for(country_code: "gb", date: Date.new(2028, 4, 5))
    assert_equal 2028, TaxCategory.tax_year_for(country_code: "gb", date: Date.new(2027, 12, 31))
  end

  test "German and Swiss catalogues are numbered by calendar year" do
    assert_equal 2028, TaxCategory.tax_year_for(country_code: "de", date: Date.new(2028, 7, 5))
    assert_equal 2028, TaxCategory.tax_year_for(country_code: "ch", date: Date.new(2028, 12, 31))
  end

  test "no date, no year" do
    assert_nil TaxCategory.tax_year_for(country_code: "gb", date: nil)
  end

  # The rule comes from the DECLARATION, not from `if country_code == "gb"`,
  # which made Britain the only country that could have a tax year not ending in
  # December. That is what lets Ireland or India arrive as a header line rather
  # than another branch in this model.
  test "a country's tax year end comes from its files, not from its name" do
    TaxSchemeConfig.stub(:tax_year_ends, "06-30") do
      # Australia: 1 Jul 2028 – 30 Jun 2029, numbered by the year it ends in.
      assert_equal 2028, TaxCategory.tax_year_for(country_code: "au", date: Date.new(2028, 6, 30))
      assert_equal 2029, TaxCategory.tax_year_for(country_code: "au", date: Date.new(2028, 7, 1))
    end
  end

  test "a country that declares nothing gets the calendar year" do
    TaxSchemeConfig.stub(:tax_year_ends, TaxSchemeConfig::DEFAULT_TAX_YEAR_END) do
      assert_equal 2028, TaxCategory.tax_year_for(country_code: "ro", date: Date.new(2028, 1, 1))
      assert_equal 2028, TaxCategory.tax_year_for(country_code: "ro", date: Date.new(2028, 12, 31))
    end
  end

  # A typo must not silently misfile a year of figures. 31 February is not a
  # date, and sliding it to the 28th would move every posting in February into
  # the wrong tax year with nothing to say so.
  test "an impossible tax year end falls back to the calendar year and complains" do
    TaxSchemeConfig.stub(:tax_year_ends, "02-31") do
      assert_equal 2028, TaxCategory.tax_year_for(country_code: "xx", date: Date.new(2028, 7, 5))
    end
  end

  # --- picking the catalogue for a period ----------------------------------

  test "the reported year wins, not whichever row the database returns last" do
    category(year: 2028, key: "office", export_column: "24")
    category(year: 2029, key: "office", export_column: "27")

    assert_equal "24", TaxCategory.for_period(scheme: SCHEME, keys: ["office"], year: 2028)["office"].export_column
    assert_equal "27", TaxCategory.for_period(scheme: SCHEME, keys: ["office"], year: 2029)["office"].export_column
  end

  test "a year with no file of its own falls back to the newest earlier one" do
    # Contributors skip years in which the rules did not change.
    category(year: 2028, key: "office", export_column: "24")

    assert_equal "24", TaxCategory.for_period(scheme: SCHEME, keys: ["office"], year: 2031)["office"].export_column
  end

  test "nothing is returned for a period before the catalogue begins" do
    category(year: 2028, key: "office", export_column: "24")

    assert_empty TaxCategory.for_period(scheme: SCHEME, keys: ["office"], year: 2027)
  end

  # The effective year is taken for the SCHEME, not per key. A box dropped in
  # 2029 is genuinely absent when reporting 2029 — resolving each key on its own
  # would resurrect it from 2028 and file a figure into a box that no longer
  # exists.
  test "a key dropped in the newer year is absent when reporting that year" do
    category(year: 2028, key: "office",  export_column: "24")
    category(year: 2028, key: "retired", export_column: "25")
    category(year: 2029, key: "office",  export_column: "27")

    for_2029 = TaxCategory.for_period(scheme: SCHEME, keys: %w[office retired], year: 2029)
    assert_equal %w[office], for_2029.keys
    assert_nil for_2029["retired"]

    for_2028 = TaxCategory.for_period(scheme: SCHEME, keys: %w[office retired], year: 2028)
    assert_equal %w[office retired].sort, for_2028.keys.sort
  end

  test "asking for nothing gets nothing, without a query" do
    assert_empty TaxCategory.for_period(scheme: SCHEME, keys: [], year: 2029)
    assert_empty TaxCategory.for_period(scheme: nil, keys: ["office"], year: 2029)
    assert_empty TaxCategory.for_period(scheme: SCHEME, keys: ["office"], year: nil)
  end
end
