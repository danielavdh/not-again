# frozen_string_literal: true
require "test_helper"
require "csv"

module Reports
  class ProfitLossCsvTest < ActiveSupport::TestCase
    def income_account
      accounts(:income_sales)
    end

    def expense_account
      accounts(:expenses_general)
    end

    def build_data(income_amt: 200, expense_amt: 80, currencies: ["GBP"])
      inc = income_account
      exp = expense_account
      {
        # The controller always supplies this now; a file names what actually
        # answered, and names nothing when nothing did.
        rate_sources: [ExchangeRate.source_for("GBP")],
        income_accounts: [inc],
        expense_accounts: [exp],
        currencies_with_data: currencies,
        income_by_currency: { inc.id => { "GBP" => income_amt } },
        expense_by_currency: { exp.id => { "GBP" => expense_amt } },
        account_translated: { inc.id => income_amt, exp.id => expense_amt },
        totals: {
          income_by_currency: Hash.new(0).merge("GBP" => income_amt),
          expense_by_currency: Hash.new(0).merge("GBP" => expense_amt),
          translated_income: income_amt,
          translated_expense: expense_amt
        }
      }
    end

    test "generates metadata rows" do
      csv = ProfitLossCsv.new(
        data: build_data,
        display_currency: "GBP",
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      assert_equal "Profit & Loss", rows[0][1]
      assert_match "2026-01-01", rows[1][1]
      assert_equal "GBP", rows[2][1]
      assert_equal "hmrc", rows[3][1]
    end

    test "includes INCOME section with account row" do
      csv = ProfitLossCsv.new(
        data: build_data,
        display_currency: "GBP",
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      inc = income_account
      account_row = rows.find { |r| r[0] == inc.code }
      assert account_row, "expected income account row"
      assert_equal "2.00", account_row[2]
    end

    test "includes Total Income row" do
      csv = ProfitLossCsv.new(
        data: build_data,
        display_currency: "GBP",
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      total_income = rows.find { |r| r[1] == I18n.t("reports.csv.total_income") }
      assert total_income, "expected Total Income row"
      assert_equal "2.00", total_income[2]
    end

    test "includes EXPENSES section with account row" do
      csv = ProfitLossCsv.new(
        data: build_data,
        display_currency: "GBP",
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      exp = expense_account
      account_row = rows.find { |r| r[0] == exp.code }
      assert account_row, "expected expense account row"
    end

    test "includes NET PROFIT/LOSS row" do
      csv = ProfitLossCsv.new(
        data: build_data(income_amt: 200, expense_amt: 80),
        display_currency: "GBP",
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      net_row = rows.find { |r| r[1] == "NET PROFIT/LOSS" }
      assert net_row, "expected NET PROFIT/LOSS row"
      assert_equal "1.20", net_row[2]
    end

    test "includes FX variance when non-zero" do
      csv = ProfitLossCsv.new(
        data: build_data,
        display_currency: "GBP",
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 3, 31),
        fx_variance: 10
      ).generate
      rows = CSV.parse(csv)
      assert rows.any? { |r| r[1] == I18n.t("reports.fx_translation_variance") }
      assert rows.any? { |r| r[1] == I18n.t("reports.net_profit_loss_adjusted") }
    end

    # The exporter must not DERIVE the source from the display currency: it
    # prints what actually answered, supplied by the caller, because deriving it
    # can name a series that was never consulted. Choosing the source for a
    # currency is ExchangeRate.source_for; printing it faithfully is this file's
    # job.
    test "prints the source it is given, not one derived from the currency" do
      csv = ProfitLossCsv.new(
        data: build_data.merge(rate_sources: ["ecb"]),
        display_currency: "EUR",
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      assert_equal "ecb", rows[3][1]
    end
  end
end
