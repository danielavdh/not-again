# frozen_string_literal: true

require "test_helper"

# Archives::SweepJob is the safety net under closing and the on-demand button,
# so it only fires for an entity or family that has neither. What is asserted is
# the shape: covered stays untouched, uncovered gets exactly one archive, empty
# stays empty, and the year checked is two back from today.
#
# perform_now sweeps EVERY entity, including fixture entity 10, which has real
# 2024 activity and so is swept as a side effect of every test here. Each test
# therefore uses its OWN dedicated entity code — the suite runs in parallel
# processes sharing the real filesystem, and two tests writing the same code
# raced intermittently.
class Archives::SweepJobTest < ActiveJob::TestCase
  setup do
    @checked_year = Date.current.year - 2
  end

  teardown do
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "10"))
  end

  def entity_with_income(code, date, amount: 100)
    entity = Entity.create!(name: "Sweep Test #{code}", code: code, active: true)
    income = Account.create!(code: "4#{code}001", name: "Sales", account_type: :income, active: true)
    bank   = Account.create!(code: "1#{code}001", name: "Bank",  account_type: :asset, currency: "GBP", active: true)
    je = JournalEntry.new(entry_date: date, posted: true, memo: "sweep test income")
    je.postings.build(account: income, entry_type: :credit, amount: amount)
    je.postings.build(account: bank,   entry_type: :debit,  amount: amount, currency: "GBP")
    je.save!
    entity
  end

  test "checks the year before the one that just ended, not the one that just ended" do
    entity = entity_with_income("41", Date.new(@checked_year, 6, 1))
    Archives::SweepJob.perform_now
    entries = Archives::Storage.list(Archives::Storage.scope_key_for(entity))
    assert_equal [ Date.new(@checked_year, 12, 31) ], entries.map(&:end_date)
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "41"))
  end

  test "an entity with an existing archive covering that year is left alone" do
    entity    = entity_with_income("42", Date.new(@checked_year, 6, 1))
    scope_key = Archives::Storage.scope_key_for(entity)
    key       = Archives::Storage.key_for(scope_key, Date.new(@checked_year, 12, 31), year_end: true)
    Archives::Storage.upload(key, "already archived")

    Archives::SweepJob.perform_now

    assert_equal "already archived", Archives::Storage.read(key)
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "42"))
  end

  test "an entity with no activity that year gets nothing forced on it" do
    entity = Entity.create!(name: "Sweep Test 43", code: "43", active: true)
    Archives::SweepJob.perform_now
    assert_empty Archives::Storage.list(Archives::Storage.scope_key_for(entity))
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "43"))
  end

  test "the generated archive is protected, same as a real close" do
    entity = entity_with_income("44", Date.new(@checked_year, 6, 1))
    Archives::SweepJob.perform_now
    assert Archives::Storage.list(Archives::Storage.scope_key_for(entity)).first.year_end
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "44"))
  end

  test "a family is swept once, not once per member" do
    group  = EntityGroup.create!(name: "Sweep Family Test")
    entity = entity_with_income("45", Date.new(@checked_year, 6, 1))
    entity.update!(entity_group: group)
    backdate_family_membership!(entity)
    Entity.create!(name: "Sweep Sibling", code: "46", active: true, entity_group: group)

    Archives::SweepJob.perform_now

    scope_key = Archives::Storage.scope_key_for(entity.reload)
    assert_equal 1, Archives::Storage.list(scope_key).size
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "g#{group.id}")) if group
  end
end
