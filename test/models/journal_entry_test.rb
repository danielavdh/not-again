# frozen_string_literal: true

require "test_helper"

class JournalEntryTest < ActiveSupport::TestCase
  def setup
    @bank_gbp = accounts(:bank_gbp)
    @bank_eur = accounts(:bank_eur)
    @daughter_bank = accounts(:daughter_bank)
    @income = accounts(:income_sales)
    @expense = accounts(:expenses_general)
    @expense_fees = accounts(:expenses_fees)
    @personal = accounts(:personal_drawings)
  end

  test "valid journal entry with balanced postings" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @income, amount: 10000, entry_type: :credit, currency: "GBP")
    assert je.valid?, je.errors.full_messages.join(", ")
  end

  test "invalid without postings" do
    je = JournalEntry.new(entry_date: Date.current)
    assert_not je.valid?
    assert je.errors[:base].any? { |e| e.match?(/posting/i) }
  end

  test "cannot save with all blank postings via nested attributes" do
    je = JournalEntry.new(
      entry_date: Date.current,
      postings_attributes: {
        "0" => { account_id: "", amount: "", amount_display: "", entry_type: "debit" },
        "1" => { account_id: "", amount: "", amount_display: "", entry_type: "credit" }
      }
    )
    assert_not je.save
    assert je.errors[:base].any?
  end

  test "invalid without entry_date" do
    je = JournalEntry.new
    assert_not je.valid?
    assert_includes je.errors[:entry_date], "can\'t be blank"
  end

  test "balanced? returns true when debits equal credits" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @income, amount: 10000, entry_type: :credit, currency: "GBP")

    assert je.balanced?
  end

  test "balanced? returns false when debits do not equal credits" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @income, amount: 5000, entry_type: :credit, currency: "GBP")

    assert_not je.balanced?
  end

  test "balanced? handles currency exchange between balance accounts" do
    je = JournalEntry.new(entry_date: Date.current)
    # Transfer from GBP to EUR (exchange)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :credit, currency: "GBP")
    je.postings.build(account: @bank_eur, amount: 11500, entry_type: :debit, currency: "EUR")

    # Each currency balances independently (single posting each) - this is
    # unbalanced
    assert je.balanced?
  end

  test "balanced? with simple deposit" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @income, amount: 10000, entry_type: :credit, currency: nil)

    assert je.balanced?
  end

  test "balanced? fails when amounts differ" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @income, amount: 5000, entry_type: :credit, currency: nil)

    assert_not je.balanced?
  end
  
  test "balanced? ignores postings marked for destruction" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @income, amount: 10000, entry_type: :credit, currency: "GBP")

    extra = je.postings.build(account: @expense, amount: 5000, entry_type: :debit, currency: "GBP")
    extra.mark_for_destruction

    assert je.balanced?
  end

  test "validation error when saving unbalanced entry" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @income, amount: 5000, entry_type: :credit, currency: "GBP")

    assert_not je.save
    assert je.errors[:base].any?
  end

  test "valid with at least one balance sheet account" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @income, amount: 10000, entry_type: :credit, currency: "GBP")

    assert je.valid?
  end

  test "invalid without any balance sheet account" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @income, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @expense, amount: 10000, entry_type: :credit, currency: "GBP")

    assert_not je.valid?
    assert je.errors[:base].any?
  end

  test "valid with liability account" do
    liability = accounts(:accounts_payable)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: liability, amount: 10000, entry_type: :credit, currency: "GBP")
    je.postings.build(account: @expense, amount: 10000, entry_type: :debit, currency: "GBP")

    assert je.valid?
  end

  test "valid with equity account" do
    equity = accounts(:equity_capital)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: equity, amount: 10000, entry_type: :credit, currency: "GBP")
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")

    assert je.valid?
  end

  test "post! succeeds when balanced" do
    je = JournalEntry.new(entry_date: Date.current, posted: false)
    je.save(validate: false)
    je.postings.create!(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.create!(account: @income, amount: 10000, entry_type: :credit, currency: "GBP")

    assert je.post!
    assert je.posted?
  end

  test "post! fails when unbalanced" do
    je = JournalEntry.new(entry_date: Date.current, posted: false)
    je.save(validate: false)
    je.postings.create!(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.create!(account: @income, amount: 5000, entry_type: :credit)

    assert_not je.post!
    assert_not je.posted?
  end

  test "unpost! sets posted to false" do
    je = journal_entries(:posted_deposit)
    assert je.posted?

    je.unpost!
    assert_not je.posted?
  end

  test "auto_post_if_balanced sets posted true on save when balanced" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @income, amount: 10000, entry_type: :credit, currency: "GBP")

    je.save!
    assert je.posted?
  end

  test "transfer_mode? returns true when from_account_id present" do
    je = JournalEntry.new(entry_date: Date.current)
    je.from_account_id = @bank_gbp.id

    assert je.transfer_mode?
  end

  test "transfer_mode? returns true when to_account_id present" do
    je = JournalEntry.new(entry_date: Date.current)
    je.to_account_id = @daughter_bank.id

    assert je.transfer_mode?
  end

  test "transfer_mode? returns false when neither account set" do
    je = JournalEntry.new(entry_date: Date.current)

    assert_not je.transfer_mode?
  end

  test "transfer validation requires to_account_id" do
    je = JournalEntry.new(entry_date: Date.current)
    je.from_account_id = @bank_gbp.id
    je.transfer_amount = 10000

    assert_not je.valid?
    assert je.errors[:to_account_id].any?
  end

  test "transfer validation requires from_account_id" do
    je = JournalEntry.new(entry_date: Date.current)
    je.to_account_id = @daughter_bank.id
    je.transfer_amount = 10000

    assert_not je.valid?
    assert je.errors[:from_account_id].any?
  end

  test "transfer validation requires different accounts" do
    je = JournalEntry.new(entry_date: Date.current)
    je.from_account_id = @bank_gbp.id
    je.to_account_id = @bank_gbp.id
    je.transfer_amount = 10000

    assert_not je.valid?
    assert je.errors[:to_account_id].any?
  end

  test "transfer validation requires positive amount" do
    je = JournalEntry.new(entry_date: Date.current)
    je.from_account_id = @bank_gbp.id
    je.to_account_id = @daughter_bank.id
    je.transfer_amount = 0

    assert_not je.valid?
    assert je.errors[:transfer_amount_display].any?
  end

  test "transfer_amount_display= converts decimal to cents" do
    je = JournalEntry.new
    je.transfer_amount_display = "123.45"

    assert_equal 12345, je.transfer_amount
  end

  test "transfer_amount_display returns decimal from cents" do
    je = JournalEntry.new
    je.transfer_amount = 12345

    assert_equal 123.45, je.transfer_amount_display
  end

  test "transfer_amount_display handles nil" do
    je = JournalEntry.new

    assert_nil je.transfer_amount_display
  end

  test "transfer_amount_display_formatted returns locale-formatted string" do
    je = JournalEntry.new
    je.transfer_amount = 123456

    formatted = je.transfer_amount_display_formatted
    assert_match(/1.*234.*56/, formatted)  # Should contain 1,234.56 or 1.234,56
  end

  test "accepts nested attributes for postings" do
    je = JournalEntry.new(
      entry_date: Date.current,
      postings_attributes: [
        { account_id: @bank_gbp.id, amount: 10000, entry_type: :debit, currency: "GBP" },
        { account_id: @income.id, amount: 10000, entry_type: :credit, currency: "GBP" }
      ]
    )

    assert je.save
    assert_equal 2, je.postings.count
  end

  test "rejects blank postings in nested attributes" do
    je = JournalEntry.new(
      entry_date: Date.current,
      postings_attributes: [
        { account_id: @bank_gbp.id, amount: 10000, entry_type: :debit, currency: "GBP" },
        { account_id: @income.id, amount: 10000, entry_type: :credit, currency: "GBP" },
        { account_id: "", amount: "", amount_display: "" }  # Should be rejected
      ]
    )

    assert je.save
    assert_equal 2, je.postings.count
  end

  test "rejects new postings with zero amount_display" do
    je = JournalEntry.new(
      entry_date: Date.current,
      postings_attributes: [
        { account_id: @bank_gbp.id, amount: 10000, entry_type: :debit, currency: "GBP" },
        { account_id: @income.id, amount: 10000, entry_type: :credit, currency: "GBP" },
        { account_id: @income.id, amount_display: "0", entry_type: :credit }  # Should be rejected
      ]
    )

    assert je.save
    assert_equal 2, je.postings.count
  end

  test "does not reject existing postings with zero amount_display via nested attributes" do
    je = journal_entries(:posted_deposit)
    posting = je.postings.first

    # Existing posting with id present — reject_if must not silently discard it
    result = je.update(
      postings_attributes: [
        { id: posting.id, amount_display: "0", entry_type: posting.entry_type, account_id: posting.account_id }
      ]
    )

    assert_not result
    assert je.errors.any?
  end

  test "allows destroying postings via nested attributes" do
    je = journal_entries(:posted_deposit)

    # Destroying a posting will unbalance the entry, so we expect validation to
    # fail
    posting_to_destroy = je.postings.first

    result = je.update(
      postings_attributes: [
        { id: posting_to_destroy.id, _destroy: true }
      ]
    )

    # Should fail validation because entry becomes unbalanced
    assert_not result
    assert je.errors[:base].any?
  end

  test "posted scope returns only posted entries" do
    posted = JournalEntry.posted

    assert posted.all?(&:posted?)
  end

  test "unposted scope returns only unposted entries" do
    unposted = JournalEntry.unposted

    assert unposted.none?(&:posted?)
  end

  test "default_order sorts unposted first, then id descending" do
    entries = JournalEntry.default_order.limit(10).to_a

    entries.each_cons(2) do |a, b|
      # unposted (draft) entries sort before posted ones
      assert !(a.posted? && !b.posted?), "unposted entries should come first"
      # within the same posted status, id descends
      assert a.id > b.id, "ids should descend within a posted group" if a.posted? == b.posted?
    end
  end

  test "by_date_range scope filters by date" do
    start_date = Date.current - 7.days
    end_date = Date.current

    entries = JournalEntry.by_date_range(start_date, end_date)

    entries.each do |entry|
      assert entry.entry_date >= start_date
      assert entry.entry_date <= end_date
    end
  end

  test "total_debits sums debit posting amounts" do
    je = journal_entries(:posted_deposit)

    expected = je.postings.debit.sum(:amount)
    assert_equal expected, je.total_debits
  end

  test "total_credits sums credit posting amounts" do
    je = journal_entries(:posted_deposit)

    expected = je.postings.credit.sum(:amount)
    assert_equal expected, je.total_credits
  end

  test "a brand new hand-built entry cannot post into the retained-earnings account" do
    re = accounts(:re_gbp_entity10)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 5000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: re, amount: 5000, entry_type: :credit)

    assert_not je.valid?
    assert je.errors[:base].any? { |e| e.match?(/maintained by the year-end close/i) }
    assert_not je.save
  end

  test "the app itself can post into the retained-earnings account, with the flag raised" do
    re = accounts(:re_gbp_entity10)
    je = JournalEntry.new(entry_date: Date.current, closing_entry: true)
    je.postings.build(account: @bank_gbp, amount: 5000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: re, amount: 5000, entry_type: :credit)

    Current.app_closing_entry_write = true
    assert je.valid?, je.errors.full_messages.join(", ")
  ensure
    Current.app_closing_entry_write = false
  end

  test "removing the retained-earnings leg from an already-saved app-owned close does not unlock it" do
    closing = journal_entries(:closing_entry_fy2024)
    re_posting = closing.postings.joins(:account).where(accounts: { locked: true, account_type: :equity }).first

    closing.memo = "trying to sneak this through"
    closing.postings_attributes = [ { id: re_posting.id, _destroy: "1" } ]

    assert_not closing.valid?
    assert closing.errors[:base].any? { |e| e.match?(/maintained by the year-end close/i) }
  end
end
