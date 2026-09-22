# frozen_string_literal: true
require "test_helper"

class Archives::GenerateTest < ActiveSupport::TestCase
  setup do
    @entity = entities(:family_biz)
    backdate_family_membership!(@entity)
    @scope = Archives::Storage.scope_key_for(@entity.reload)
  end

  teardown do
    FileUtils.rm_rf(uploads_path("archives", @scope))
  end

  test "generates and uploads, and the result is readable back" do
    key = Archives::Generate.call(scope_key: @scope, year: Date.current.year, year_end: true)

    assert_equal Archives::Storage.key_for(@scope, Date.current.year, year_end: true), key
    assert_includes Archives::Storage.read(key), "EntryID,Date,Entity,AccountCode"
  end

  test "year_end: true uses the protected filename shape" do
    key = Archives::Generate.call(scope_key: @scope, year: Date.current.year, year_end: true)
    assert Archives::Storage.entry_for(key).year_end
  end

  test "a header-only year is not uploaded" do
    empty_scope = "g#{rand(10_000..99_999)}"
    assert_nil Archives::Generate.call(scope_key: empty_scope, year: 2019, year_end: true)
    assert_empty Archives::Storage.list(empty_scope)
  end
end
