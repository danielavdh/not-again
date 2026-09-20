# frozen_string_literal: true
require "test_helper"

class EntityGroupTest < ActiveSupport::TestCase
  setup do
    @group = EntityGroup.create!(name: "Household")
    @personal   = entities(:personal)    # entity 01
    @family_biz = entities(:family_biz)   # entity 10
  end

  test "an ungrouped entity is its own group" do
    assert_equal [@personal.code], @personal.group_codes
  end

  test "grouped entities share all their family codes" do
    @personal.update!(entity_group: @group)
    @family_biz.update!(entity_group: @group)

    assert_equal %w[01 10], @personal.reload.group_codes.sort
    assert_equal %w[01 10], @family_biz.reload.group_codes.sort
  end

  test "family_codes_for expands a member to the whole family" do
    @personal.update!(entity_group: @group)
    @family_biz.update!(entity_group: @group)

    assert_equal %w[01 10], Entity.family_codes_for(%w[01]).sort
  end

  test "family_codes_for leaves ungrouped codes untouched" do
    assert_equal %w[04], Entity.family_codes_for(%w[04])
  end

  test "deleting a group ungroups its members and keeps their timeline history intact" do
    travel_to(Date.new(2024, 1, 1)) do
      @personal.update!(entity_group: @group)
      @family_biz.update!(entity_group: @group)
    end
    group_stint = @personal.entity_group_memberships.order(:starts_on).find { |m| m.entity_group_id == @group.id }

    @group.destroy

    assert_nil @personal.reload.entity_group_id
    assert_equal @group.id, group_stint.reload.entity_group_id,
      "the timeline is append-only — the stint still records which scope its archives live under"
    assert_equal [ nil, @group.id, nil ], @personal.entity_group_memberships.order(:starts_on).map(&:entity_group_id)
  end

  test "membership is non-dissolvable once a cross-entity entry exists" do
    @personal.update!(entity_group: @group)   # 01 joins (allowed)
    @family_biz.update!(entity_group: @group) # 10 joins (allowed)
    build_cross_entity_je # links 01 and 10

    @personal.entity_group = nil
    assert_not @personal.valid?, "leaving should be blocked"
    assert @personal.errors[:base].any?
  end

  test "joining a family is allowed even with an existing cross-entity entry" do
    build_cross_entity_je # 01 and 10, both still ungrouped
    assert @personal.update(entity_group: @group), @personal.errors.full_messages.join(", ")
  end

  test "cannot leave while this entity's OWN report group holds a sibling's account" do
    @personal.update!(entity_group: @group)
    @family_biz.update!(entity_group: @group)
    rg = @personal.report_groups.create!(name: "Consolidated")
    rg.report_group_accounts.create!(account: accounts(:bank_gbp), position: 0) # entity 10's account

    @personal.entity_group = nil

    assert_not @personal.valid?
    assert @personal.errors[:base].any?
  end

  test "cannot leave while a SIBLING's report group holds this entity's account" do
    @personal.update!(entity_group: @group)
    @family_biz.update!(entity_group: @group)
    rg = @family_biz.report_groups.create!(name: "Consolidated")
    rg.report_group_accounts.create!(account: accounts(:boss_bank), position: 0) # entity 01's account

    @personal.entity_group = nil

    assert_not @personal.valid?
    assert @personal.errors[:base].any?
  end

  test "leaving is allowed once no shared journal entries or report group accounts remain" do
    @personal.update!(entity_group: @group)
    @family_biz.update!(entity_group: @group)
    # no cross-entity JE, no cross-referencing report_group_accounts at all

    @personal.entity_group = nil

    assert @personal.valid?, @personal.errors.full_messages.join(", ")
  end

  test "a report group referencing accounts OUTSIDE the family being left does not block leaving" do
    @personal.update!(entity_group: @group)
    rg = @personal.report_groups.create!(name: "Solo report")
    rg.report_group_accounts.create!(account: accounts(:boss_bank), position: 0) # 01's own account

    @personal.entity_group = nil

    assert @personal.valid?, @personal.errors.full_messages.join(", ")
  end

  private

  # A grandfathered cross-entity JE between entity 01 and entity 10, saved
  # without validation (the rule would otherwise reject it).
  def build_cross_entity_je
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: accounts(:boss_bank), amount: 5000, entry_type: :debit,  currency: "GBP") # 01
    je.postings.build(account: accounts(:bank_gbp),  amount: 5000, entry_type: :credit, currency: "GBP") # 10
    je.save!(validate: false)
    je
  end
end
