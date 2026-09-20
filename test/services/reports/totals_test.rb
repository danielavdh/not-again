# frozen_string_literal: true
require "test_helper"

# These three calculators were calculate_*_totals in ReportsController — about
# 170 lines of arithmetic reading a dozen instance variables set earlier in the
# same action. Reports::CustomReport had always done this job properly for SAVED
# reports; the general three never got the same treatment.
#
# The point of the extraction is this file: the figures on a financial statement
# can be checked against known inputs, without driving a request.
class Reports::TotalsTest < ActiveSupport::TestCase
  setup do
    @month = Date.new(2026, 3, 1)
    # 1 EUR = 0.80 GBP, published. HMRC, because a GBP report reads HMRC —
    # the source follows the DISPLAY currency, not the one being converted.
    ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", source: "hmrc",
                              rate: 0.8, effective_date: @month,
                              valid_from: @month, valid_to: @month.end_of_month)

    @entity  = Entity.find_by(code: "01") || Entity.create!(code: "01", name: "One", active: true)
    @account = Account.new(id: 1, code: "1013001", currency: "EUR")
  end

  def args(extra = {})
    { display_currency: "GBP", currencies_with_data: %w[EUR] }.merge(extra)
  end

  # ---- profit and loss ----

  test "income and expenditure translate, and the bottom line falls out" do
    income  = Account.new(id: 1, code: "1041001", currency: "EUR")
    expense = Account.new(id: 2, code: "1051001", currency: "EUR")

    calc = Reports::ProfitLossTotals.new(
      income_accounts:     [ income ],
      expense_accounts:    [ expense ],
      income_by_currency:  { 1 => { "EUR" => 10_000 } },
      expense_by_currency: { 2 => { "EUR" =>  4_000 } },
      balances_by_month:   { 1 => { @month => { "EUR" => 10_000 } },
                             2 => { @month => { "EUR" =>  4_000 } } },
      **args
    )

    account_translated, totals = calc.call

    assert_equal 8_000, account_translated[1], "10,000 EUR at 0.80"
    assert_equal 3_200, account_translated[2]
    assert_equal 10_000, totals[:income_by_currency]["EUR"]
    assert_equal 6_000,  totals[:net_by_currency]["EUR"], "in the currency itself"
    assert_equal 4_800,  totals[:translated_net], "and translated"
  end

  # ---- trial balance ----

  # Debits and credits translate SEPARATELY: a trial balance's monthly bucket
  # holds a pair, not a single amount, which is why it cannot share the base
  # class's translate_monthly.
  test "debits and credits translate as two sides" do
    calc = Reports::TrialBalanceTotals.new(
      accounts:             [ @account ],
      balances_by_currency: { 1 => { "EUR" => { debit: 10_000, credit: 2_500 } } },
      balances_by_month:    { 1 => { @month => { "EUR" => { debit: 10_000, credit: 2_500 } } } },
      **args
    )

    account_translated, totals = calc.call

    assert_equal({ debit: 8_000, credit: 2_000 }, account_translated[1])
    assert_equal 10_000, totals[:debit_by_currency]["EUR"]
    assert_equal 8_000,  totals[:translated_debit]
    assert_equal 2_000,  totals[:translated_credit]
  end

  test "an account with no balances is skipped entirely" do
    calc = Reports::TrialBalanceTotals.new(
      accounts: [ @account ], balances_by_currency: {}, balances_by_month: {}, **args
    )
    account_translated, totals = calc.call

    assert_empty account_translated
    assert_equal 0, totals[:translated_debit]
  end

  # ---- balance sheet ----

  # ⚠️ ONE date, not one per month. A balance sheet is a position at a moment.
  test "assets, liabilities and equity translate at the closing date" do
    asset     = Account.new(id: 1, code: "1010001", currency: "EUR")
    liability = Account.new(id: 2, code: "1021001", currency: "EUR")
    equity    = Account.new(id: 3, code: "1031001", currency: "EUR")

    calc = Reports::BalanceSheetTotals.new(
      asset_accounts:       [ asset ],
      liability_accounts:   [ liability ],
      equity_accounts:      [ equity ],
      balances_by_currency: { 1 => { "EUR" => 10_000 },
                              2 => { "EUR" =>  3_000 },
                              3 => { "EUR" =>  2_000 } },
      as_of:                @month.end_of_month,
      **args
    )

    _account_translated, totals = calc.call

    assert_equal 8_000, totals[:translated_assets]
    assert_equal 4_000, totals[:translated_liability_equity], "liabilities + equity"
    assert_equal 5_000, totals[:liability_equity_by_currency]["EUR"]
    assert_equal 4_000, totals[:net_profit], "assets − (liabilities + equity)"
  end

  # ---- what they all share ----

  test "the series that answered is reported, not re-derived" do
    calc = Reports::TrialBalanceTotals.new(
      accounts:             [ @account ],
      balances_by_currency: { 1 => { "EUR" => { debit: 10_000, credit: 0 } } },
      balances_by_month:    { 1 => { @month => { "EUR" => { debit: 10_000, credit: 0 } } } },
      **args
    )
    calc.call

    assert_equal %w[hmrc], calc.rate_sources
  end

  # An entity's own elected rate applies to its own accounts — the entity comes
  # from digits 2-3 of the account code, so a CONSOLIDATED report can mix them.
  test "an entity's own rate beats the published one for its own accounts" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", source: "manual",
                              rate: 0.5, effective_date: @month, entity_id: @entity.id,
                              valid_from: @month, valid_to: @month.end_of_month)

    calc = Reports::TrialBalanceTotals.new(
      accounts:             [ @account ],
      balances_by_currency: { 1 => { "EUR" => { debit: 10_000, credit: 0 } } },
      balances_by_month:    { 1 => { @month => { "EUR" => { debit: 10_000, credit: 0 } } } },
      **args
    )
    account_translated, = calc.call

    assert_equal 5_000, account_translated[1][:debit],
                 "account code 1013001 is entity 01, whose own rate is 0.50"
  end
end
