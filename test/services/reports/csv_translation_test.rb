# frozen_string_literal: true
require "test_helper"
require "ostruct"

# THE ONE TEST THAT MATTERS FOR TRANSLATED EXPORTS.
#
# Every other CSV test compares against I18n.t(...), which is right — a
# hardcoded "Total Income" asserts the language rather than the structure. But
# it means a MISSING key passes: "Translation missing: …" equals itself.
#
# So this renders every exporter in every language and looks for the marker. It
# is the only thing standing between a missing key and an accountant opening a
# file whose headers read "Translation missing: en.reports.csv.section", and it
# says exactly which key and which language.
class Reports::CsvTranslationTest < ActiveSupport::TestCase
  MARKER = /translation missing/i

  def profit_loss
    inc = accounts(:income_sales)
    exp = accounts(:expenses_general)
    Reports::ProfitLossCsv.new(
      data: {
        rate_sources: %w[hmrc],
        income_accounts: [ inc ], expense_accounts: [ exp ],
        currencies_with_data: %w[GBP EUR],
        income_by_currency:  { inc.id => { "GBP" => 200 } },
        expense_by_currency: { exp.id => { "GBP" => 80 } },
        account_translated:  { inc.id => 200, exp.id => 80 },
        totals: { income_by_currency: Hash.new(0).merge("GBP" => 200),
                  expense_by_currency: Hash.new(0).merge("GBP" => 80),
                  translated_income: 200, translated_expense: 80 }
      },
      display_currency: "GBP", fx_variance: 500,
      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31)
    ).generate
  end

  def balance_sheet
    asset = accounts(:bank_gbp)
    Reports::BalanceSheetCsv.new(
      data: {
        rate_sources: %w[hmrc],
        asset_accounts: [ asset ], liability_accounts: [], equity_accounts: [],
        currencies_with_data: %w[GBP EUR],
        balances_by_currency: { asset.id => { "GBP" => 1000 } },
        account_translated: { asset.id => 1000 },
        totals: { asset_by_currency: Hash.new(0).merge("GBP" => 1000),
                  liability_by_currency: Hash.new(0), equity_by_currency: Hash.new(0),
                  translated_assets: 1000, translated_liabilities: 0, translated_equity: 0 }
      },
      display_currency: "GBP", end_date: Date.new(2026, 3, 31)
    ).generate
  end

  def trial_balance
    a = accounts(:bank_gbp)
    Reports::TrialBalanceCsv.new(
      data: {
        rate_sources: %w[hmrc], accounts: [ a ],
        currencies_with_data: %w[GBP EUR],
        balances_by_currency: { a.id => { "GBP" => { debit: 1000, credit: 0 } } },
        account_translated: { a.id => { debit: 1000, credit: 0 } },
        totals: { debit_by_currency: Hash.new(0).merge("GBP" => 1000),
                  credit_by_currency: Hash.new(0),
                  translated_debit: 1000, translated_credit: 0 }
      },
      display_currency: "GBP", fx_variance: 500, end_date: Date.new(2026, 3, 31)
    ).generate
  end

  def standard
    Reports::StandardCsv.new(
      report: nil,
      data: { rate_sources: %w[hmrc], currencies: %w[GBP EUR], parent_groups: [],
              show_type_totals: false },
      display_currency: "GBP", short_version: true
    ).generate
  end

  def tax_report
    group  = OpenStruct.new(display_name: "GB-self-employment", tax_scheme: "gb_self_employment")
    report = OpenStruct.new(report_group: group, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31))
    Reports::TaxReportCsv.new(
      report: report, display_currency: "GBP", short_version: false,
      receipts: { 1 => %w[http://x/1] }, unlinked_receipts: [ { date: Date.new(2026, 2, 1), title: "R", url: "http://x/2" } ],
      data: {
        rate_sources: %w[hmrc], currencies: %w[GBP EUR],
        category_groups: [ {
          key: "sales_income", label: "Turnover", reference: "15", section: "income",
          section_header: "income", preceding_section_total: nil,
          currency_totals: { "GBP" => 1000 }, translated_total: 1000,
          accounts: [ { code: "410001", name: "Sales", currency_totals: { "GBP" => 1000 },
                        translated_total: 1000, entries: [ { date: Date.new(2026, 2, 1), description: "inv",
                        currency: "GBP", amount: 1000, translated_amount: 1000, posting_id: 1 } ] } ]
        } ],
        section_totals: { "income" => { currency_totals: { "GBP" => 1000 }, translated_total: 1000 } },
        net: { currency_totals: { "GBP" => 1000 }, translated_total: 1000 },
        last_section: "income"
      }
    ).generate
  end

  def all_exports
    { "profit and loss" => profit_loss, "balance sheet" => balance_sheet,
      "trial balance" => trial_balance, "saved report" => standard, "tax report" => tax_report }
  end

  test "no export carries a missing translation, in any language" do
    missing = []

    %i[en de nl es].each do |locale|
      I18n.with_locale(locale) do
        all_exports.each do |name, csv|
          csv.to_s.scan(/translation missing: \S+/i) { |m| missing << "#{locale}  #{name}  #{m}" }
        end
      end
    end

    assert_empty missing.uniq, "\n  " + missing.uniq.join("\n  ")
  end

  # The words really do change — a guard against the whole thing quietly falling
  # back to English, which is what it did before and looked fine.
  test "a German export is actually in German" do
    en = I18n.with_locale(:en) { profit_loss }
    de = I18n.with_locale(:de) { profit_loss }

    assert_not_equal en, de, "the export must not be identical in every language"
    assert_includes de, I18n.t("reports.csv.report", locale: :de)
  end
end
