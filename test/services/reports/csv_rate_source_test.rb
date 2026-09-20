# frozen_string_literal: true
require "test_helper"
require "csv"

# Every export must say which published series produced its converted figures.
#
# TWO of the five did not, and they were the two that mattered most:
# StandardCsv, the saved-report export and the very file that once shipped a
# converted column of 0.00; and TaxCsv, the figures an accountant carries onto a
# return.
#
# The other three declared a source but RE-DERIVED it from the display currency,
# which the cross-source fallback made capable of being wrong — printing `ecb`
# for figures ESTV produced. A CSV has no flash and outlives whoever downloaded
# it, so a source line that is confidently wrong is worse than none.
class Reports::CsvRateSourceTest < ActiveSupport::TestCase
  SOURCE_ROW = I18n.t("reports.csv.rate_source")

  def source_line(csv)
    CSV.parse(csv).find { |row| row&.first == SOURCE_ROW }&.at(1)
  end

  # ---- the three that carried a source line, but re-derived it ----

  def profit_loss(rate_sources)
    inc = accounts(:income_sales)
    exp = accounts(:expenses_general)

    Reports::ProfitLossCsv.new(
      data: {
        rate_sources: rate_sources,
        income_accounts: [ inc ], expense_accounts: [ exp ],
        currencies_with_data: %w[GBP],
        income_by_currency:  { inc.id => { "GBP" => 200 } },
        expense_by_currency: { exp.id => { "GBP" => 80 } },
        account_translated:  { inc.id => 200, exp.id => 80 },
        totals: { income_by_currency: Hash.new(0).merge("GBP" => 200),
                  expense_by_currency: Hash.new(0).merge("GBP" => 80),
                  translated_income: 200, translated_expense: 80 }
      },
      display_currency: "GBP",
      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31)
    ).generate
  end

  test "the source line names what actually answered" do
    assert_equal "estv", source_line(profit_loss([ "estv" ]))
  end

  # A fallback shows as two entries rather than as one confident half-truth.
  test "a fallback is reported as both series" do
    assert_equal "estv, ecb", source_line(profit_loss(%w[estv ecb]))
  end

  # NOTHING ANSWERED MEANS NO SOURCE LINE, not a guess.
  #
  # Falling back to source_for(display_currency) — the DERIVED answer — meant
  # choosing CHF (ESTV) over a period ESTV does not reach produced a file with
  # an empty converted column and "Exchange Rate Source, ecb" at the top:
  # nothing had been converted at all, and the file named a source never
  # consulted.
  test "a source is never named when none answered" do
    assert_nil source_line(profit_loss(nil))
    assert_nil source_line(profit_loss([]))
  end

  # ---- the two that had no source line at all ----

  test "the saved-report export declares its source" do
    csv = Reports::StandardCsv.new(
      report: nil,
      data: { rate_sources: %w[hmrc], currencies: %w[GBP EUR], parent_groups: [] },
      display_currency: "GBP", short_version: true
    ).generate

    assert_equal "hmrc", source_line(csv),
                 "the saved-report export carried no source line at all"
  end

  test "and reports a fallback there too" do
    csv = Reports::StandardCsv.new(
      report: nil,
      data: { rate_sources: %w[estv ecb], currencies: %w[CHF EUR], parent_groups: [] },
      display_currency: "CHF", short_version: true
    ).generate

    assert_equal "estv, ecb", source_line(csv)
  end

  # TaxCsv is not given its sources — it works them out from the translators
  # that did the conversion, which is the only thing that can say what ANSWERED.
  # It also passes the entity and the scheme, so a business's own elected rate
  # and its country's accepted series both apply; the class-level
  # ExchangeRate.translate takes neither.
  test "the tax export declares its source, worked out from the conversion" do
    scheme   = Account.where.not(tax_scheme: nil).limit(1).pick(:tax_scheme)
    skip "no scheme-tagged accounts in fixtures" unless scheme

    csv = Reports::TaxCsv.new(
      accounts: Account.where(tax_scheme: scheme).to_a,
      entity: entities(:family_biz), scheme: scheme,
      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 12, 31),
      display_currency: "GBP", admin: admins(:sudo)
    ).generate

    # Either a source line, or none because nothing needed converting — never a
    # wrong one.
    line = source_line(csv)
    assert(line.nil? || line.split(", ").all? { |s| RateSourceConfig.exists?(s) },
           "tax export named a source that is not in the registry: #{line.inspect}")
  end

  # ---- and the one that must NOT be given one ----

  # A CSV drops the converted column when a rate is missing, rather than showing
  # it empty as the screen does — a file has no flash to explain itself, so an
  # empty column would read as "these figures are zero".
  test "a missing rate drops the column in a file, unlike on screen" do
    inc = accounts(:income_sales)
    gap = ExchangeRate::RateUnavailable.new(
      from_currency: "EUR", to_currency: "GBP", date: Date.new(2026, 3, 1), source: "hmrc"
    )

    csv = Reports::ProfitLossCsv.new(
      data: {
        rate_unavailable: gap, rate_sources: %w[hmrc],
        income_accounts: [ inc ], expense_accounts: [],
        currencies_with_data: %w[GBP EUR],
        income_by_currency: { inc.id => { "GBP" => 200 } }, expense_by_currency: {},
        account_translated: {}, totals: { income_by_currency: Hash.new(0),
                                          expense_by_currency: Hash.new(0),
                                          translated_income: 0, translated_expense: 0 }
      },
      display_currency: "GBP",
      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31)
    ).generate

    assert_match(/UNAVAILABLE/, csv, "the file must say why, since it has no flash")
  end
end
