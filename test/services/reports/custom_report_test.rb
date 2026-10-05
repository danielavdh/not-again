# frozen_string_literal: true

require "test_helper"

module Reports
  # The parent subtotal rows: how they are named, and what they sum.
  class CustomReportTest < ActiveSupport::TestCase
    setup do
      @admin  = admins(:two)
      @entity = Entity.create!(code: "71", name: "Parent Rules Co", active: true)
      AdminEntity.create!(admin: @admin, entity: @entity, access_level: 0)

      @parent = Account.create!(code: "571000", name: "Premises", account_type: :expense)
      @a = Account.create!(code: "571001", name: "Rent",    account_type: :expense, parent: @parent)
      @b = Account.create!(code: "571002", name: "Rates",    account_type: :expense, parent: @parent)
      @c = Account.create!(code: "571003", name: "Cleaning", account_type: :expense, parent: @parent)
      @bank = Account.create!(code: "171000", name: "Bank", account_type: :asset, currency: "GBP")

      [ @a, @b, @c ].each { |acct| post(acct, 10_00) }

      @group = ReportGroup.create!(name: "Parent test", entity: @entity)
    end

    def post(expense, cents)
      je = JournalEntry.new(entry_date: Date.current, memo: "x", posted: true)
      je.postings.build(account: expense, entry_type: :debit,  amount: cents)
      je.postings.build(account: @bank,   entry_type: :credit, amount: cents, currency: "GBP")
      je.save!
    end

    def report_over(*accounts)
      accounts.each_with_index { |acc, i| ReportGroupAccount.create!(report_group: @group, account: acc, position: i) }
      report = @group.reports.create!(name: "r", start_date: Date.current.beginning_of_year, end_date: Date.current.end_of_year)
      CustomReport.new(report: report, display_currency: "GBP", short_version: true, admin: @admin).generate
    end

    def only_group(data)
      data[:parent_groups].find { |g| g[:accounts].size > 1 }
    end

    test "all of a parent's children present: the subtotal is named after the parent" do
      g = only_group(report_over(@a, @b, @c))
      assert_equal "571000 - Premises", g[:total_name]
      assert_equal "571000", g[:parent_code]
      assert_equal 30_00, g[:currency_totals]["GBP"]
    end

    # A report is a chosen set of accounts, and each subtotal lists its own
    # accounts directly above it — so leaving a sibling out changes nothing
    # about what to call the group. The label used to become a list of the codes
    # it covered, "(571001, 571003)", which repeated the rows above it in
    # digits; and the parent code was blanked, so the row lost its only
    # identifier.
    test "leaving a sibling out changes nothing but the figure" do
      g = only_group(report_over(@a, @c)) # 571002 omitted

      assert_equal "571000 - Premises", g[:total_name]
      assert_equal "571000", g[:parent_code]
      assert_equal 20_00, g[:currency_totals]["GBP"], "and it sums only the two that are in"
    end

    test "a child in the report with no activity is no different" do
      idle = Account.create!(code: "571009", name: "Idle", account_type: :expense, parent: @parent)
      g = only_group(report_over(@a, @b, @c, idle)) # idle just has £0
      assert_equal "571000 - Premises", g[:total_name]
    end
  end
end
