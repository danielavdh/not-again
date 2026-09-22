# frozen_string_literal: true
require "test_helper"

# The trigger brain: which calendar years get an undeletable archive, and when.
#
# Each test uses its OWN random 2-digit entity code and cleans up only its own
# scope dirs.
class Archives::YearEndTest < ActiveSupport::TestCase
  setup { @scopes = [] }

  teardown do
    @scopes.uniq.each do |s|
      FileUtils.rm_rf(uploads_path("archives", s))
    end
  end

  def uniq_code
    loop do
      c = format("%02d", rand(10..99))
      break c unless Entity.exists?(code: c)
    end
  end

  def born(on: Date.new(2019, 1, 1))
    code = uniq_code
    e = travel_to(on) { Entity.create!(code: code, name: code, active: true) }
    @scopes << code
    bank = Account.create!(code: "1#{code}001", name: "Bank #{code}", account_type: :asset, currency: "GBP")
    inc  = Account.create!(code: "4#{code}001", name: "Sales #{code}", account_type: :income)
    [ e, bank, inc ]
  end

  def post(bank, inc, date, memo = "e")
    je = JournalEntry.new(entry_date: date, memo: memo)
    je.postings.build(account: bank, amount: 1000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: inc,  amount: 1000, entry_type: :credit)
    je.posted = true
    je.save!
  end

  # "Close" through end_date by planting a closing entry whose period covers it.
  def close_through(bank, start_on, end_on)
    je = JournalEntry.new(entry_date: end_on, memo: "close", closing_entry: true,
                          period_start: start_on, period_end: end_on)
    je.postings.build(account: bank, amount: 0, entry_type: :debit, currency: "GBP")
    je.postings.build(account: bank, amount: 0, entry_type: :credit, currency: "GBP")
    je.posted = true
    je.save!(validate: false)
  end

  test "a solo entity's year is written only once it has closed through year-end" do
    e, bank, inc = born
    post(bank, inc, Date.new(2023, 5, 1), "sale 2023")

    Archives::YearEnd.after_close(e)
    assert_empty Archives::Storage.list(e.code), "not closed yet"

    close_through(bank, Date.new(2023, 1, 1), Date.new(2023, 12, 31))
    Archives::YearEnd.after_close(e)

    entries = Archives::Storage.list(e.code)
    assert_equal [ 2023 ], entries.map(&:year)
    assert_includes Archives::Storage.read(entries.first.key), "sale 2023"
  end

  test "a family year waits for the last sibling, across staggered fiscal years" do
    group = EntityGroup.create!(name: "Staggered #{rand(9999)}")
    de, de_bank, de_inc = born
    uk, uk_bank, uk_inc = born
    travel_to(Date.new(2020, 1, 1)) { de.update!(entity_group: group); uk.update!(entity_group: group) }
    scope = "g#{group.id}"
    @scopes << scope

    post(de_bank, de_inc, Date.new(2023, 3, 1), "de 2023")
    post(uk_bank, uk_inc, Date.new(2023, 9, 1), "uk 2023")

    close_through(de_bank, Date.new(2023, 1, 1), Date.new(2023, 12, 31))
    Archives::YearEnd.after_close(de)
    assert_empty Archives::Storage.list(scope), "UK hasn't closed through 2023-12-31 yet"

    close_through(uk_bank, Date.new(2023, 4, 1), Date.new(2024, 3, 31)) # FY2023/24 covers 2023-12-31
    Archives::YearEnd.after_close(uk)

    entries = Archives::Storage.list(scope)
    assert_equal [ 2023 ], entries.map(&:year)
    body = Archives::Storage.read(entries.first.key)
    assert_includes body, "de 2023"
    assert_includes body, "uk 2023"
  end

  test "a member with no activity in the year does not block the family archive" do
    group = EntityGroup.create!(name: "Dormant #{rand(9999)}")
    a, a_bank, a_inc = born
    b, = born # never posts, never closes
    travel_to(Date.new(2020, 1, 1)) { a.update!(entity_group: group); b.update!(entity_group: group) }
    @scopes << "g#{group.id}"

    post(a_bank, a_inc, Date.new(2023, 5, 1), "a 2023")
    close_through(a_bank, Date.new(2023, 1, 1), Date.new(2023, 12, 31))
    Archives::YearEnd.after_close(a)

    assert_equal [ 2023 ], Archives::Storage.list("g#{group.id}").map(&:year)
  end

  test "force writes a year regardless of close state, but not twice" do
    e, bank, inc = born
    post(bank, inc, Date.new(2022, 5, 1), "sale 2022")

    Archives::YearEnd.force(e.code, 2022)
    assert_equal [ 2022 ], Archives::Storage.list(e.code).map(&:year)

    Archives::Storage.upload(Archives::Storage.list(e.code).first.key, "kept")
    Archives::YearEnd.force(e.code, 2022)
    assert_equal "kept", Archives::Storage.read(Archives::Storage.list(e.code).first.key), "force is a no-op once covered"
  end

  test "refresh rebuilds an existing year in place and skips a year with no archive" do
    e, bank, inc = born
    post(bank, inc, Date.new(2023, 5, 1), "original")
    Archives::YearEnd.force(e.code, 2023)

    post(bank, inc, Date.new(2023, 8, 1), "correction")
    Archives::YearEnd.refresh(e.code, Date.new(2023, 8, 1))
    assert_includes Archives::Storage.read(Archives::Storage.list(e.code).find { |x| x.year == 2023 }.key), "correction"

    before = Archives::Storage.list(e.code).map(&:year).sort
    Archives::YearEnd.refresh(e.code, Date.new(2021, 1, 1)) # no 2021 archive → no-op
    assert_equal before, Archives::Storage.list(e.code).map(&:year).sort
  end
end
