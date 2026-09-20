# frozen_string_literal: true
require "test_helper"
require "csv"

# A NUMBER IN A SPREADSHEET IS NOT A NUMBER IN A STRING.
#
# Writing "2300.05" whatever language the user is in means that, opened in a
# German, Dutch or Spanish Excel — where the decimal separator is a comma — the
# column arrives as TEXT, and every total the accountant tries to take comes out
# empty or wrong. Silently, because a spreadsheet does not complain about text.
#
# One language, one convention, chosen for the largest country that speaks it:
# de → Germany, nl → Netherlands, es → Spain, en → the UK. A Swiss user gets the
# German file, since Switzerland writes 2'300.05, and can always download in
# English.
class Reports::CsvLocaleFormatTest < ActiveSupport::TestCase
  test "the decimal separator follows the language" do
    assert_equal "2300.05", CurrencyConfig.format_cents_csv(230_005, locale: :en)

    %i[de nl es].each do |locale|
      assert_equal "2300,05", CurrencyConfig.format_cents_csv(230_005, locale: locale),
                   "#{locale} writes a decimal comma"
    end
  end

  # NO THOUSANDS SEPARATOR, deliberate rather than an omission. "2.300,05" is
  # how a German writes it on paper, but a spreadsheet READING a file wants the
  # digits unbroken — grouping is the reader's job, applied by cell format. A
  # stray dot inside a number is the fastest way to have the whole column parsed
  # as text again.
  test "digits are never broken up, in any language" do
    %i[en de nl es].each do |locale|
      assert_no_match(/\d[.,]\d{3}/, CurrencyConfig.format_cents_csv(123_456_789, locale: locale),
                      "#{locale} must not group thousands in a file")
    end
  end

  # A comma decimal and a comma column separator collide, and the whole file
  # lands in one column. Excel's own convention, and what Datev has always done.
  test "a comma decimal forces a semicolon column separator" do
    assert_equal ",", CurrencyConfig.csv_separator(locale: :en)

    %i[de nl es].each do |locale|
      assert_equal ";", CurrencyConfig.csv_separator(locale: locale)
    end
  end

  test "an exporter really uses the separator, end to end" do
    inc = accounts(:income_sales)
    data = {
      rate_sources: %w[hmrc],
      income_accounts: [ inc ], expense_accounts: [],
      currencies_with_data: %w[GBP],
      income_by_currency: { inc.id => { "GBP" => 230_005 } }, expense_by_currency: {},
      account_translated: { inc.id => 230_005 },
      totals: { income_by_currency: Hash.new(0).merge("GBP" => 230_005),
                expense_by_currency: Hash.new(0),
                translated_income: 230_005, translated_expense: 0 }
    }

    I18n.with_locale(:de) do
      csv = Reports::ProfitLossCsv.new(
        data: data, display_currency: "GBP",
        start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31)
      ).generate

      assert_includes csv, "2300,05", "the German file must carry a decimal comma"
      assert_includes csv, ";",       "and a semicolon column separator"
      # Parsed back with the right separator, the amount is a single field.
      assert CSV.parse(csv, col_sep: ";").flatten.include?("2300,05")
    end
  end

  test "nil stays empty, not zero" do
    assert_equal "", CurrencyConfig.format_cents_csv(nil, locale: :de)
  end
end
