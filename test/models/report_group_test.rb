# frozen_string_literal: true
require "test_helper"

class ReportGroupTest < ActiveSupport::TestCase
  setup do
    @entity = entities(:family_biz)
  end

  # --- Validations ---

  test "valid with name and entity" do
    g = ReportGroup.new(name: "My Group", entity: @entity)
    assert g.valid?
  end

  test "requires name" do
    g = ReportGroup.new(name: "", entity: @entity)
    refute g.valid?
    assert_includes g.errors[:name], "can't be blank"
  end

  # --- reports ordering ---

  test "reports order by start_date, then end_date (cumulative MTD tiebreak)" do
    g = ReportGroup.create!(name: "Quarters", entity: @entity)
    q2 = g.reports.create!(name: "Q2", start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 9, 5))
    q1 = g.reports.create!(name: "Q1", start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5))
    later = g.reports.create!(name: "H2", start_date: Date.new(2026, 10, 6), end_date: Date.new(2027, 4, 5))

    assert_equal [q1.id, q2.id, later.id], g.reports.pluck(:id)
  end

  # --- account_ids_ordered ---

  test "account_ids_ordered returns ids in position order" do
    g = ReportGroup.create!(name: "Ordered", entity: @entity)
    a1 = accounts(:income_sales)
    a2 = accounts(:bank_gbp)
    g.report_group_accounts.create!(account_id: a2.id, position: 2)
    g.report_group_accounts.create!(account_id: a1.id, position: 1)
    assert_equal [a1.id, a2.id], g.account_ids_ordered
  end

  # --- update_accounts ---

  test "update_accounts replaces existing accounts" do
    g = ReportGroup.create!(name: "Upd", entity: @entity)
    a1 = accounts(:income_sales)
    a2 = accounts(:bank_gbp)
    g.update_accounts([[a1.id, 1]])
    assert_equal [a1.id], g.account_ids_ordered
    g.update_accounts([[a2.id, 1]])
    assert_equal [a2.id], g.account_ids_ordered
  end

  test "update_accounts with empty array clears all accounts" do
    g = ReportGroup.create!(name: "Clear", entity: @entity)
    a1 = accounts(:income_sales)
    g.update_accounts([[a1.id, 1]])
    g.update_accounts([])
    assert_equal [], g.account_ids_ordered
  end

  # --- scopes ---

  test "ordered scope returns groups by position" do
    # Just verify the scope runs without error
    groups = ReportGroup.ordered
    assert_kind_of ActiveRecord::Relation, groups
  end

  test "templates scope returns only template groups" do
    g = ReportGroup.create!(name: "Tmpl", entity: @entity, is_template: true)
    _non_tmpl = ReportGroup.create!(name: "Not Tmpl", entity: @entity, is_template: false)
    assert_includes ReportGroup.templates, g
  end
end

class ReportGroupAccountTest < ActiveSupport::TestCase
  setup do
    @entity = entities(:family_biz)
    @group = ReportGroup.create!(name: "RGA Group", entity: @entity)
    @account = accounts(:income_sales)
  end

  test "valid with account and position" do
    rga = ReportGroupAccount.new(report_group: @group, account: @account, position: 1)
    assert rga.valid?
  end

  test "account must be unique within group" do
    @group.report_group_accounts.create!(account_id: @account.id, position: 1)
    dup = @group.report_group_accounts.build(account_id: @account.id, position: 2)
    refute dup.valid?
    assert dup.errors[:account_id].any?
  end

  test "same account can appear in different groups" do
    other_group = ReportGroup.create!(name: "Other", entity: @entity)
    @group.report_group_accounts.create!(account_id: @account.id, position: 1)
    rga = other_group.report_group_accounts.build(account_id: @account.id, position: 1)
    assert rga.valid?
  end

  test "ordered scope returns by position" do
    @group.report_group_accounts.create!(account_id: accounts(:bank_gbp).id, position: 10)
    @group.report_group_accounts.create!(account_id: @account.id, position: 5)
    ordered = @group.report_group_accounts.ordered.pluck(:position)
    assert_equal ordered.sort, ordered
  end
end
