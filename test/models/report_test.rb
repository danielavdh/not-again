# frozen_string_literal: true
require "test_helper"

class ReportTest < ActiveSupport::TestCase
  setup do
    @entity = entities(:family_biz)
    @group = ReportGroup.create!(name: "Test Group", entity: @entity)
  end

  def valid_attrs
    { name: "Q1 2026", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31) }
  end

  # --- Validations ---

  test "valid report saves" do
    r = @group.reports.build(valid_attrs)
    assert r.valid?
  end

  test "requires name" do
    r = @group.reports.build(valid_attrs.merge(name: ""))
    refute r.valid?
    assert_includes r.errors[:name], "can't be blank"
  end

  test "requires start_date" do
    r = @group.reports.build(valid_attrs.merge(start_date: nil))
    refute r.valid?
    assert_includes r.errors[:start_date], "can't be blank"
  end

  test "requires end_date" do
    r = @group.reports.build(valid_attrs.merge(end_date: nil))
    refute r.valid?
    assert_includes r.errors[:end_date], "can't be blank"
  end

  test "end_date must be after start_date" do
    r = @group.reports.build(valid_attrs.merge(end_date: Date.new(2026, 1, 1)))
    refute r.valid?
    assert r.errors[:end_date].any?
  end

  test "equal dates are invalid" do
    r = @group.reports.build(valid_attrs.merge(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 1)))
    refute r.valid?
  end

  test "valid when end_date one day after start_date" do
    r = @group.reports.build(valid_attrs.merge(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2)))
    assert r.valid?
  end

  # --- Associations ---

  test "belongs to report_group" do
    r = @group.reports.create!(valid_attrs)
    assert_equal @group, r.report_group
  end

  test "delegates account_ids_ordered to report_group" do
    account = accounts(:income_sales)
    @group.update_accounts([[account.id, 1]])
    r = @group.reports.create!(valid_attrs)
    assert_includes r.account_ids_ordered, account.id
  end
end
