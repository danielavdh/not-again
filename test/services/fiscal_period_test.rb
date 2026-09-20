# frozen_string_literal: true

require "test_helper"

class FiscalPeriodTest < ActiveSupport::TestCase
  setup do
    @entity = Entity.create!(name: "Fiscal Test", code: "77", active: true)
    @income = Account.create!(code: "477001", name: "Sales", account_type: :income, active: true)
    @asset  = Account.create!(code: "177001", name: "Bank", account_type: :asset, currency: "GBP", active: true)
    @year   = Date.current.year
  end

  def post_income(date, amount: 100)
    je = JournalEntry.new(entry_date: date, posted: true, memo: "t #{date}")
    je.postings.build(account: @income, entry_type: :credit, amount: amount)
    je.postings.build(account: @asset, entry_type: :debit, amount: amount, currency: "GBP")
    je.save!
    je
  end

  def close(start_date, end_date)
    YearEndService.new(entity: @entity, start_date:, end_date:).call
  end

  test "first close, calendar pattern, runs from business start to that year's 31 Dec" do
    post_income(Date.new(@year - 2, 3, 15))
    r = FiscalPeriod.next_for(@entity, pattern: "calendar")
    assert r.ready?
    assert_equal Date.new(@year - 2, 3, 15), r.start_date
    assert_equal Date.new(@year - 2, 12, 31), r.end_date
  end

  test "first close, uk pattern, ends on the first 5 April on or after the start" do
    post_income(Date.new(@year - 2, 7, 5))
    r = FiscalPeriod.next_for(@entity, pattern: "uk")
    assert r.ready?
    assert_equal Date.new(@year - 2, 7, 5), r.start_date
    assert_equal Date.new(@year - 1, 4, 5), r.end_date
  end

  test "first close, uk_fy pattern, ends on the first 31 March on or after the start" do
    post_income(Date.new(@year - 2, 7, 5))
    r = FiscalPeriod.next_for(@entity, pattern: "uk_fy")
    assert r.ready?
    assert_equal Date.new(@year - 2, 7, 5), r.start_date
    assert_equal Date.new(@year - 1, 3, 31), r.end_date
  end

  test "last_closed_on returns the entity's most recent closing period end" do
    assert_nil FiscalPeriod.last_closed_on(@entity)
    post_income(Date.new(@year - 1, 6, 1))
    YearEndService.new(entity: @entity,
      start_date: Date.new(@year - 1, 1, 1), end_date: Date.new(@year - 1, 12, 31)).call
    assert_equal Date.new(@year - 1, 12, 31), FiscalPeriod.last_closed_on(@entity)
  end

  # A pro may close a year by hand rather than using the assisted flow. Marking
  # that entry as a closing entry is what makes it count towards the dashboard's
  # "closed up to" note, alongside the automated ones.
  test "last_closed_on counts a hand-built closing entry the user has marked" do
    equity = Account.create!(code: "377001", name: "Owner equity",
                                  account_type: :equity, currency: "GBP", active: true)
    post_income(Date.new(@year - 2, 6, 1))

    manual = JournalEntry.new(entry_date: Date.new(@year - 2, 12, 31),
                                   memo: "Manual close", posted: true, closing_entry: true)
    manual.postings.build(account: @income, entry_type: :debit,  amount: 100)
    manual.postings.build(account: equity,  entry_type: :credit, amount: 100, currency: "GBP")
    manual.save!

    # derived, because the user supplied no dates
    assert_equal Date.new(@year - 2, 12, 31), manual.period_end
    assert_equal Date.new(@year - 2, 1, 1),   manual.period_start
    assert_equal Date.new(@year - 2, 12, 31), FiscalPeriod.last_closed_on(@entity)
  end

  test "an explicit closing period is kept, and an out-of-order one is rejected" do
    equity = Account.create!(code: "377002", name: "Owner equity 2",
                                  account_type: :equity, currency: "GBP", active: true)
    je = JournalEntry.new(entry_date: Date.new(@year - 1, 3, 31),
                               posted: true, closing_entry: true,
                               period_start: Date.new(@year - 2, 4, 1),
                               period_end:   Date.new(@year - 1, 3, 31))
    je.postings.build(account: @income, entry_type: :debit,  amount: 100)
    je.postings.build(account: equity,  entry_type: :credit, amount: 100, currency: "GBP")
    assert je.save
    assert_equal Date.new(@year - 2, 4, 1), je.period_start

    je.period_start = Date.new(@year, 1, 1)
    assert_not je.valid?
    assert je.errors[:period_start].any?
  end

  # A closing entry the app generated belongs to the app: it is destroyed and
  # rebuilt on every in-period change, so any hand edit would be discarded at
  # the next recalculation. Users cannot edit or delete one at all — the way
  # back is reopening the year, which takes the whole period's entries together.
  test "an app-generated close is read-only to users" do
    post_income(Date.new(@year - 1, 6, 1))
    close(Date.new(@year - 1, 1, 1), Date.new(@year - 1, 12, 31))
    generated = JournalEntry.where(closing_entry: true).order(:id).last
    assert generated.posts_to_locked_retained_earnings?

    generated.memo = "annotated by hand"
    assert_not generated.valid?, "editing an app-generated close must be rejected"

    generated.reload.closing_entry = false
    assert_not generated.valid?, "unflagging an app-generated close must be rejected"

    generated.reload.period_end = Date.new(@year - 1, 11, 30)
    assert_not generated.valid?, "re-dating an app-generated close must be rejected"

    assert_not generated.reload.destroy, "deleting one by hand must be refused"
    assert JournalEntry.exists?(generated.id)
  end

  test "the app itself may rewrite its closing entries when it announces the write" do
    post_income(Date.new(@year - 1, 6, 1))
    close(Date.new(@year - 1, 1, 1), Date.new(@year - 1, 12, 31))
    generated = JournalEntry.where(closing_entry: true).order(:id).last

    Current.app_closing_entry_write = true
    assert generated.destroy, "the recalculation and reopen-year paths must still work"
    assert_not JournalEntry.exists?(generated.id)
  ensure
    Current.app_closing_entry_write = false
  end

  test "a hand-built close remains freely editable" do
    equity = Account.create!(code: "377003", name: "Owner equity 3",
                                  account_type: :equity, currency: "GBP", active: true)
    post_income(Date.new(@year - 2, 6, 1))
    manual = JournalEntry.new(entry_date: Date.new(@year - 2, 12, 31),
                                   posted: true, closing_entry: true)
    manual.postings.build(account: @income, entry_type: :debit,  amount: 100)
    manual.postings.build(account: equity,  entry_type: :credit, amount: 100, currency: "GBP")
    manual.save!

    manual.period_start = Date.new(@year - 2, 4, 1)
    manual.period_end   = Date.new(@year - 2, 12, 31)
    assert manual.valid?, "a user's own closing entry stays theirs to edit"
  end

  test "a year that has not finished yet is not closeable" do
    post_income(Date.new(@year, 1, 5))
    r = FiscalPeriod.next_for(@entity, pattern: "calendar")
    assert r.not_finished?
    assert_equal Date.new(@year, 12, 31), r.end_date
  end

  test "subsequent close advances one year from the last closing entry" do
    post_income(Date.new(@year - 2, 6, 1))
    close(Date.new(@year - 2, 1, 1), Date.new(@year - 2, 12, 31))
    post_income(Date.new(@year - 1, 6, 1))

    r = FiscalPeriod.next_for(@entity)
    assert r.ready?
    assert_equal Date.new(@year - 1, 1, 1), r.start_date
    assert_equal Date.new(@year - 1, 12, 31), r.end_date
  end

  test "elapsed years with nothing to close are skipped" do
    post_income(Date.new(@year - 3, 6, 1))
    close(Date.new(@year - 3, 1, 1), Date.new(@year - 3, 12, 31))
    # year-2 dormant (no postings)
    post_income(Date.new(@year - 1, 6, 1))

    r = FiscalPeriod.next_for(@entity)
    assert r.ready?
    assert_equal Date.new(@year - 1, 1, 1), r.start_date
    assert_equal Date.new(@year - 1, 12, 31), r.end_date
  end

  test "backlog flag is set when more elapsed years remain after the offered one" do
    post_income(Date.new(@year - 3, 1, 1))
    post_income(Date.new(@year - 2, 6, 1))
    post_income(Date.new(@year - 1, 6, 1))

    r = FiscalPeriod.next_for(@entity, pattern: "calendar")
    assert r.ready?
    assert_equal Date.new(@year - 3, 1, 1), r.start_date
    assert_equal Date.new(@year - 3, 12, 31), r.end_date
    assert r.backlog
  end

  test "no entries at all yields :none" do
    r = FiscalPeriod.next_for(@entity, pattern: "calendar")
    assert r.none?
  end

  test "an impossible recurring year-end (29 Feb) raises InvalidYearEnd" do
    post_income(Date.new(2023, 1, 1)) # 2023 is not a leap year
    assert_raises(FiscalPeriod::InvalidYearEnd) do
      FiscalPeriod.next_for(@entity, year_end_month: 2, year_end_day: 29)
    end
  end
end
