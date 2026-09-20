# frozen_string_literal: true

require "test_helper"

module Reports
  # Reports::TaxReport groups the scheme's accounts by tax category, bands them
  # income / expenses / other, and totals to a net line — from the same
  # LedgerBalances and Translation the submission reads, so the report a
  # bookkeeper sees and the figure filed can never disagree.
  class TaxReportTest < ActiveSupport::TestCase
    setup do
      @entity  = entities(:family_biz) # code 10
      @admin   = admins(:two)
      @income  = accounts(:income_sales)      # 410001 — deposit_income: +10_000 credit
      @expense = accounts(:expenses_general)  # 510001 — withdrawal_expense: +5_000 debit
      @fees    = accounts(:expenses_fees)     # 510002 — multi_deposit_fees: +500 debit

      Dir[Rails.root.join("db/tax_categories/gb_self_employment*.yml")].each { |f| TaxCategoryLoader.call(f) }
      @entity.update!(tax_schemes: %w[gb_self_employment])
      @income.update!(tax_scheme: "gb_self_employment",  tax_category_key: "sales_income")
      @expense.update!(tax_scheme: "gb_self_employment", tax_category_key: "premises_running_costs")
      @fees.update!(tax_scheme: "gb_self_employment",    tax_category_key: "premises_running_costs")

      @group  = ReportGroup.create!(name: "GB SE", entity: @entity, tax_scheme: "gb_self_employment")
      @report = @group.reports.create!(name: "SE", start_date: Date.current.beginning_of_year,
                                       end_date: Date.current.end_of_year)
    end

    def generate(short: false)
      TaxReport.new(report: @report, display_currency: "GBP", short_version: short, admin: @admin).generate
    end

    test "accounts are grouped under their tax category, income before expenses" do
      d = generate
      keys = d[:category_groups].map { |g| g[:key] }
      assert_includes keys, "sales_income"
      assert_includes keys, "premises_running_costs"
      assert_equal %w[income expenses], d[:category_groups].map { |g| g[:section] }.uniq

      running = d[:category_groups].find { |g| g[:key] == "premises_running_costs" }
      assert_equal %w[510001 510002], running[:accounts].map { |a| a[:code] }.sort
    end

    test "a category total is the sum of its member accounts" do
      running = generate[:category_groups].find { |g| g[:key] == "premises_running_costs" }
      member_sum = running[:accounts].sum { |a| a[:currency_totals]["GBP"].to_i }
      assert_equal member_sum, running[:currency_totals]["GBP"]
      assert_equal 5_500, running[:currency_totals]["GBP"] # 5_000 + 500
    end

    test "section totals and the net line" do
      d = generate
      # income_sales: deposit_income 10_000 + multi_deposit_income 10_000
      assert_equal 20_000, d[:section_totals]["income"][:currency_totals]["GBP"]
      # withdrawal_expense 5_000 + multi_deposit_fees 500
      assert_equal 5_500,  d[:section_totals]["expenses"][:currency_totals]["GBP"]
      assert_equal 14_500, d[:net][:currency_totals]["GBP"]
      assert_equal 14_500, d[:net][:translated_total] # GBP books, GBP scheme — no translation
    end

    test "the detail form carries the transactions and they foot to the category total" do
      running = generate(short: false)[:category_groups].find { |g| g[:key] == "premises_running_costs" }
      entries = running[:accounts].flat_map { |a| a[:entries] }
      assert entries.any?, "detail form must carry the transactions"
      assert_equal running[:currency_totals]["GBP"], entries.sum { |e| e[:amount] }
    end

    test "every category total equals what the submission would file for it" do
      d = generate
      filed = Reports::TaxCategoryTotals.new(
        accounts: @report.accounts.to_a, scheme: "gb_self_employment",
        from: @report.start_date, to: @report.end_date,
        display_currency: "GBP", entity: @entity
      ).totals

      d[:category_groups].each do |g|
        next unless filed.key?(g[:key])
        assert_equal filed[g[:key]][:amount], g[:translated_total],
          "#{g[:key]}: the report and the submission disagree"
      end
    end

    test "an inactive account with activity in the period is still in the report, flagged" do
      # Real case: closed to zero at a later year-end, then retired — the
      # earlier year's figure is still on that year's return. update_column
      # skips the balance-must-be-zero guard, which is about the deactivation
      # flow, not this.
      @fees.update_column(:active, false) # 510002 — posting in multi_posting_deposit
      running = generate[:category_groups].find { |g| g[:key] == "premises_running_costs" }

      fees_row = running[:accounts].find { |a| a[:code] == "510002" }
      assert fees_row, "an inactive account with a tax-relevant figure must not be dropped"
      assert fees_row[:inactive], "and it must be flagged as inactive"
      assert_equal 5_500, running[:currency_totals]["GBP"], "its figure still counts toward the box"
    end

    test "an inactive account with NO activity in the period is left out" do
      idle = Account.create!(code: "5#{@entity.code}909", name: "Idle", account_type: :expense,
                             active: false, tax_scheme: "gb_self_employment",
                             tax_category_key: "premises_running_costs")
      keys_codes = generate[:category_groups].flat_map { |g| g[:accounts].map { |a| a[:code] } }
      assert_not_includes keys_codes, idle.code
    end

    test "an account whose category is not in the catalogue is shown but not totalled" do
      @fees.update!(tax_category_key: "a_retired_box_that_does_not_exist")
      d = generate

      orphan = d[:category_groups].find { |g| g[:key] == "a_retired_box_that_does_not_exist" }
      assert orphan, "the account must still be visible to the bookkeeper"
      assert_nil orphan[:section]
      # its figure is in no section total
      assert_equal 5_000, d[:section_totals]["expenses"][:currency_totals]["GBP"] # only 510001 now
    end
  end
end
