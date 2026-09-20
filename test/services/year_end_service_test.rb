# frozen_string_literal: true

require "test_helper"

class YearEndServiceTest < ActiveSupport::TestCase
  setup do
    @entity     = entities(:family_biz)
    @start_date = Date.current.beginning_of_year
    @end_date   = Date.current.end_of_year
  end

  def service
    YearEndService.new(entity: @entity, start_date: @start_date, end_date: @end_date)
  end

  test "nothing_to_close? is true when no posted income/expense postings exist for entity" do
    entity = entities(:standalone)
    svc = YearEndService.new(entity: entity, start_date: @start_date, end_date: @end_date)
    assert svc.nothing_to_close?
  end

  test "call returns one posted journal entry per currency" do
    entries = service.call
    assert entries.any?
    assert entries.all? { |je| je.is_a?(JournalEntry) && je.posted? }
  end

  test "call creates locked retained earnings accounts" do
    service.call
    assert Account.retained_earnings.for_entity_codes([@entity.code]).exists?
  end

  test "each journal entry is balanced" do
    service.call.each do |je|
      debits  = je.postings.select(&:debit?).sum(&:amount)
      credits = je.postings.select(&:credit?).sum(&:amount)
      assert_equal debits, credits, "JE #{je.id} (#{je.memo}) is not balanced"
    end
  end

  test "income and expense legs carry no currency; only the retained-earnings leg does" do
    service.call.each do |je|
      je.postings.includes(:account).each do |p|
        if p.account.balance_account?
          assert p.currency.present?, "the retained-earnings leg must carry a currency"
        else
          assert_nil p.currency, "#{p.account.code} (#{p.account.account_type}) must not carry a currency"
        end
      end
    end
  end

  test "generated closing entries pass full validation" do
    # The service now saves with validations on (no validate: false). Re-
    # checking
    # a persisted close needs the same app-write flag the controller sets.
    Current.app_closing_entry_write = true
    service.call.each do |je|
      assert je.valid?, "JE #{je.id} (#{je.memo}): #{je.errors.full_messages.join(', ')}"
    end
  ensure
    Current.app_closing_entry_write = false
  end

  test "every closing entry has its retained-earnings leg" do
    service.call.each do |je|
      re_legs = je.postings.select { |p| p.account.locked? && p.account.equity? }
      assert_equal 1, re_legs.size, "JE #{je.id} (#{je.memo}) must have exactly one retained-earnings leg"
    end
  end

  # --- personal / drawings accounts close too (audit M5) -------------------

  def post_drawing(personal_account, bank_account, amount, currency, date: @end_date)
    je = JournalEntry.new(entry_date: date, memo: "drawing")
    je.postings.build(account: personal_account, amount: amount, entry_type: :debit)
    je.postings.build(account: bank_account, amount: amount, entry_type: :credit, currency: currency)
    je.posted = true
    je.save!
    je
  end

  test "a drawing on a personal account is closed into retained earnings" do
    drawings = accounts(:personal_drawings)
    post_drawing(drawings, accounts(:bank_gbp), 7_000, "GBP")

    gbp_close = service.call.find { |je| je.memo.include?("GBP") }
    drawings_leg = gbp_close.postings.find { |p| p.account_id == drawings.id }

    assert drawings_leg, "the closing entry must include the personal account"
    assert drawings_leg.credit?, "closing a drawing credits the personal account back to zero"
    assert_equal 7_000, drawings_leg.amount
    assert_equal 0, drawings.balance(start_date: @start_date, end_date: @end_date),
      "after the close the drawing no longer sits on the nominal account"
  end

  test "the drawing enlarges the retained-earnings leg by exactly the drawn amount" do
    # Close once with no drawing to get the baseline RE leg, reopen, then close
    # again with a £70 drawing added — the RE leg must move £70 further debit.
    baseline = service.call.find { |je| je.memo.include?("GBP") }
      .postings.find { |p| p.account.locked? }
    net_re = ->(p) { p.credit? ? p.amount : -p.amount }
    before = net_re.call(baseline)

    Current.app_closing_entry_write = true
    JournalEntry.where(closing_entry: true).joins(postings: :account)
      .where("SUBSTRING(accounts.code, 2, 2) = ?", @entity.code).distinct.destroy_all
    Current.app_closing_entry_write = false

    post_drawing(accounts(:personal_drawings), accounts(:bank_gbp), 7_000, "GBP")
    after_leg = service.call.find { |je| je.memo.include?("GBP") }
      .postings.find { |p| p.account.locked? }

    assert_equal before - 7_000, net_re.call(after_leg),
      "a drawing leaves that much less in retained earnings"
  end

  test "nothing_to_close? is false when the only activity is a drawing" do
    entity = entities(:standalone)
    personal = Account.create!(code: "605001", name: "Owner draw", account_type: :personal, active: true)
    je = JournalEntry.new(entry_date: @end_date, memo: "drawing")
    je.postings.build(account: personal, amount: 4_000, entry_type: :debit)
    je.postings.build(account: accounts(:standalone_bank), amount: 4_000, entry_type: :credit, currency: "GBP")
    je.posted = true
    je.save!

    svc = YearEndService.new(entity: entity, start_date: @start_date, end_date: @end_date)
    assert_not svc.nothing_to_close?
    entries = svc.call
    assert_equal 1, entries.size
    assert entries.first.postings.any? { |p| p.account_id == personal.id && p.credit? }
  end

  test "a drawing in a currency with no retained-earnings account yet creates one" do
    post_drawing(accounts(:personal_drawings), accounts(:bank_eur), 3_000, "EUR")

    assert_not Account.retained_earnings.for_entity_codes([@entity.code]).where(currency: "EUR").exists?
    service.call
    assert Account.retained_earnings.for_entity_codes([@entity.code]).where(currency: "EUR").exists?,
      "the close creates a EUR retained-earnings account on demand, as it does for income in a new currency"
  end

  # A closed year asserted in figures: the exact retained-earnings balance,
  # every nominal left at zero, and a nil P&L for the period after closing.
  test "a closed year: retained earnings equals the net, nominals zeroed, post-close P&L is nil" do
    entity = travel_to(Date.new(2019, 1, 1)) { Entity.create!(code: "63", name: "Closed Co", active: true) }
    bank   = Account.create!(code: "163001", name: "Bank",   account_type: :asset,   currency: "GBP")
    sales  = Account.create!(code: "463001", name: "Sales",  account_type: :income)
    rent   = Account.create!(code: "563001", name: "Rent",   account_type: :expense)

    post = ->(dr, cr, amt, cur_acct) {
      je = JournalEntry.new(entry_date: Date.new(2023, 6, 1), memo: "op")
      je.postings.build(account: dr, amount: amt, entry_type: :debit,  currency: (cur_acct == dr ? "GBP" : nil))
      je.postings.build(account: cr, amount: amt, entry_type: :credit, currency: (cur_acct == cr ? "GBP" : nil))
      je.posted = true
      je.save!
    }
    post.call(bank, sales, 90_000, bank)  # income  90,000
    post.call(rent, bank,  30_000, bank)  # expense 30,000

    YearEndService.new(entity: entity, start_date: Date.new(2023, 1, 1), end_date: Date.new(2023, 12, 31)).call

    re = Account.retained_earnings.for_entity_codes([ "63" ]).where(currency: "GBP").sole
    assert_equal 60_000, re.balance(start_date: Date.new(2023, 1, 1), end_date: Date.new(2023, 12, 31)),
      "retained earnings = 90,000 income − 30,000 expense"
    assert_equal 0, sales.balance(start_date: Date.new(2023, 1, 1), end_date: Date.new(2023, 12, 31)), "income closed to zero"
    assert_equal 0, rent.balance(start_date: Date.new(2023, 1, 1), end_date: Date.new(2023, 12, 31)),  "expense closed to zero"

    remaining = YearEndService.new(entity: entity, start_date: Date.new(2023, 1, 1), end_date: Date.new(2023, 12, 31))
    assert remaining.nothing_to_close?, "nothing left to close once the year is closed"
  end

  test "locked accounts cannot be updated" do
    service.call
    account = Account.retained_earnings.for_entity_codes([@entity.code]).first
    account.name = "Changed"
    assert_not account.save
  end

  test "locked accounts cannot be destroyed" do
    service.call
    account = Account.retained_earnings.for_entity_codes([@entity.code]).first
    assert_not account.destroy
  end
end
