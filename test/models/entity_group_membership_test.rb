# frozen_string_literal: true
require "test_helper"

class EntityGroupMembershipTest < ActiveSupport::TestCase
  setup do
    @group = EntityGroup.create!(name: "Household")
  end

  # Create at a fixed early date so "joins later" is a real forward move, not
  # a time-travelled one.
  def entity_born(code, on: Date.new(2020, 1, 1), **attrs)
    travel_to(on) { Entity.create!(code: code, name: code, **attrs) }
  end

  # ==================== the timeline is complete and gap-free
  # ====================

  test "a new entity opens a solo stint from its creation date" do
    e = entity_born("80", on: Date.new(2021, 5, 4))
    row = e.entity_group_memberships.sole
    assert_nil row.entity_group_id
    assert_equal Date.new(2021, 5, 4), row.starts_on
    assert_nil row.ends_on
  end

  test "joining closes the solo stint at yesterday and opens a family stint today" do
    e = entity_born("80")
    travel_to(Date.new(2026, 3, 10)) { e.update!(entity_group: @group) }

    rows = e.entity_group_memberships.order(:starts_on)
    assert_nil    rows.first.entity_group_id
    assert_equal  Date.new(2026, 3, 9), rows.first.ends_on
    assert_equal  @group.id, rows.last.entity_group_id
    assert_equal  Date.new(2026, 3, 10), rows.last.starts_on
    assert_nil    rows.last.ends_on
  end

  test "leaving opens a solo stint again — the timeline never has a gap" do
    e = entity_born("80")
    other = entity_born("81")
    travel_to(Date.new(2024, 3, 10)) { e.update!(entity_group: @group); other.update!(entity_group: @group) }
    travel_to(Date.new(2026, 8, 1))  { e.update!(entity_group: nil) }

    rows = e.entity_group_memberships.order(:starts_on).to_a
    assert_equal [ nil, @group.id, nil ], rows.map(&:entity_group_id)
    assert_equal Date.new(2026, 7, 31), rows[1].ends_on
    assert_equal Date.new(2026, 8, 1),  rows[2].starts_on
    assert_nil   rows[2].ends_on
    assert_equal 1, e.entity_group_memberships.open.count
  end

  test "no row is written when entity_group_id does not change" do
    e = entity_born("80")
    assert_no_difference("EntityGroupMembership.count") { e.update!(name: "Renamed") }
  end

  # ==================== a family needs two members ====================

  test "when a departure leaves one member, that member reverts to solo" do
    a = entity_born("80")
    b = entity_born("81")
    travel_to(Date.new(2024, 1, 1)) { a.update!(entity_group: @group); b.update!(entity_group: @group) }
    travel_to(Date.new(2026, 9, 1)) { a.update!(entity_group: nil) }

    assert_nil b.reload.entity_group_id, "a one-member family is just an entity"
    assert_equal [ nil, @group.id, nil ], b.entity_group_memberships.order(:starts_on).map(&:entity_group_id)
  end

  # ==================== Entity.scope_windows_for ====================

  test "scope_windows_for a family clamps each member to its stint within the year" do
    a = entity_born("80")
    b = entity_born("81")
    travel_to(Date.new(2024, 1, 1)) { a.update!(entity_group: @group); b.update!(entity_group: @group) }
    c = entity_born("82")
    travel_to(Date.new(2025, 3, 1)) { c.update!(entity_group: @group) }

    windows = Entity.scope_windows_for(scope_key: "g#{@group.id}", year: 2025)

    assert_equal [[ Date.new(2025, 1, 1), Date.new(2025, 12, 31) ]], windows["80"]
    assert_equal [[ Date.new(2025, 3, 1), Date.new(2025, 12, 31) ]], windows["82"], "joined 1 March — clamped"
  end

  test "scope_windows_for a solo scope covers only the days the entity was NOT in a family" do
    e = entity_born("80")
    other = entity_born("81")
    travel_to(Date.new(2025, 3, 1))   { e.update!(entity_group: @group); other.update!(entity_group: @group) }
    travel_to(Date.new(2025, 10, 15)) { e.update!(entity_group: nil) }

    windows = Entity.scope_windows_for(scope_key: "80", year: 2025)

    assert_equal [
      [ Date.new(2025, 1, 1), Date.new(2025, 2, 28) ],
      [ Date.new(2025, 10, 15), Date.new(2025, 12, 31) ]
    ], windows["80"], "solo archive = the year minus the in-family days"
  end

  test "a departed sibling still appears in the family window for the days it belonged" do
    a = entity_born("80")
    b = entity_born("81")
    c = entity_born("82")
    travel_to(Date.new(2024, 1, 1)) { [a, b, c].each { |e| e.update!(entity_group: @group) } }
    travel_to(Date.new(2025, 6, 1)) { a.update!(entity_group: nil) } # a leaves; b, c stay (≥2)

    windows = Entity.scope_windows_for(scope_key: "g#{@group.id}", year: 2025)

    assert_equal [[ Date.new(2025, 1, 1), Date.new(2025, 5, 31) ]], windows["80"], "clamped to the leave date"
    assert_equal [[ Date.new(2025, 1, 1), Date.new(2025, 12, 31) ]], windows["81"]
  end
end
