# frozen_string_literal: true
require "test_helper"

class Archives::StorageTest < ActiveSupport::TestCase
  setup do
    @scope_key = "g#{rand(10_000..99_999)}"
  end

  teardown do
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", @scope_key))
  end

  test "scope_key_for keys grouped entities by their family, not the member" do
    grouped = Entity.new(code: "20", entity_group_id: 7)
    assert_equal "g7", Archives::Storage.scope_key_for(grouped)
  end

  test "scope_key_for keys an ungrouped entity by its own code" do
    solo = Entity.new(code: "20", entity_group_id: nil)
    assert_equal "20", Archives::Storage.scope_key_for(solo)
  end

  test "upload then list then read round-trips, newest first" do
    older = Archives::Storage.key_for(@scope_key, 2025, year_end: true)
    newer = Archives::Storage.key_for(@scope_key, 2026, year_end: true)
    Archives::Storage.upload(older, "old content")
    Archives::Storage.upload(newer, "new content")

    entries = Archives::Storage.list(@scope_key)
    assert_equal [ 2026, 2025 ], entries.map(&:year)
    assert_equal "new content", Archives::Storage.read(entries.first.key)
  end

  test "listing an empty scope returns no entries, not an error" do
    assert_equal [], Archives::Storage.list(@scope_key)
  end

  test "key_for takes an integer year and dates it 31 December" do
    assert_match %r{/26-12-31-year-end-backup\.csv\z}, Archives::Storage.key_for(@scope_key, 2026, year_end: true)
  end

  test "key_for distinguishes year-end from on-demand" do
    on_demand = Archives::Storage.key_for(@scope_key, Date.new(2026, 6, 1))
    year_end  = Archives::Storage.key_for(@scope_key, 2026, year_end: true)

    assert_not_equal on_demand, year_end
    assert_match(/-backup\.csv\z/, on_demand)
    assert_match(/-year-end-backup\.csv\z/, year_end)
  end

  test "year_end_archived? is true only once an undeletable archive covers that year" do
    assert_not Archives::Storage.year_end_archived?(@scope_key, 2026)

    Archives::Storage.upload(Archives::Storage.key_for(@scope_key, Date.new(2026, 6, 1)), "x") # on-demand only
    assert_not Archives::Storage.year_end_archived?(@scope_key, 2026), "an on-demand snapshot is not the permanent record"

    Archives::Storage.upload(Archives::Storage.key_for(@scope_key, 2026, year_end: true), "x")
    assert Archives::Storage.year_end_archived?(@scope_key, 2026)
  end

  test "delete removes an uploaded archive" do
    key = Archives::Storage.key_for(@scope_key, Date.new(2026, 1, 1))
    Archives::Storage.upload(key, "x")
    assert_equal 1, Archives::Storage.list(@scope_key).size

    Archives::Storage.delete(key)
    assert_equal [], Archives::Storage.list(@scope_key)
  end

  test "member_codes_for a family lists every entity that was ever a member" do
    group = EntityGroup.create!(name: "Members Test")
    a = Entity.create!(code: "71", name: "A")
    b = Entity.create!(code: "72", name: "B")
    travel_to(Date.new(2024, 1, 1)) { a.update!(entity_group: group) }
    travel_to(Date.new(2024, 1, 1)) { b.update!(entity_group: group) }
    travel_to(Date.new(2025, 6, 1)) { a.update!(entity_group: nil) } # a leaves

    codes = Archives::Storage.member_codes_for("g#{group.id}")
    assert_includes codes, "71", "a departed member still counts — its slice is in the family archive"
    assert_includes codes, "72"
  end
end
