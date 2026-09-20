# frozen_string_literal: true

require "test_helper"

# Posting callbacks and validations not covered in posting_test.rb:
# currency_matches_account_if_required, balance_account_edit_type,
# determine_transaction_type, unlink_receipts, link_existing_receipt.
class PostingCallbacksTest < ActiveSupport::TestCase
  setup do
    @bank    = accounts(:bank_gbp)   # asset, currency: GBP
    @bank_eur = accounts(:bank_eur)  # asset, currency: EUR
    @income  = accounts(:income_sales)
    @je      = journal_entries(:posted_deposit)
  end

  # ==================== currency_matches_account_if_required
  # ====================

  test "posting with correct currency for balance account is valid" do
    p = Posting.new(
      journal_entry: JournalEntry.new(entry_date: Date.current),
      account: @bank,
      entry_type: :debit,
      amount: 10000,
      currency: "GBP"
    )
    p.valid?
    assert p.errors[:currency].none?
  end

  test "set_currency_from_account overrides any passed currency for balance accounts" do
    # set_currency_from_account runs before validation, so even passing "EUR"
    # gets overridden to the account's own currency ("GBP") before any check.
    p = Posting.new(
      journal_entry: JournalEntry.new(entry_date: Date.current),
      account: @bank,
      entry_type: :debit,
      amount: 10000,
      currency: "EUR"
    )
    p.valid?
    assert_equal "GBP", p.currency
    assert p.errors[:currency].none?
  end

  test "nominal account posting does not validate currency against account" do
    p = Posting.new(
      journal_entry: JournalEntry.new(entry_date: Date.current),
      account: @income,
      entry_type: :credit,
      amount: 10000,
      currency: nil
    )
    p.valid?
    assert p.errors[:currency].none?
  end

  # ==================== balance_account_edit_type ====================

  test "balance_account_edit_type returns deposit when counter is debit" do
    counter = [nil, nil, nil, nil, nil, "debit", nil, nil]
    assert_equal "deposit", Posting.balance_account_edit_type([counter])
  end

  test "balance_account_edit_type returns withdrawal when counter is credit" do
    counter = [nil, nil, nil, nil, nil, "credit", nil, nil]
    assert_equal "withdrawal", Posting.balance_account_edit_type([counter])
  end

  test "balance_account_edit_type returns nil for empty counter accounts" do
    assert_nil Posting.balance_account_edit_type([])
  end

  test "balance_account_edit_type returns journal_entry for 2+ counter accounts" do
    counter1 = [nil, nil, nil, nil, nil, "debit", nil, nil]
    counter2 = [nil, nil, nil, nil, nil, "credit", nil, nil]
    assert_equal "journal_entry", Posting.balance_account_edit_type([counter1, counter2])
  end

  # ==================== determine_transaction_type ====================

  test "determine_transaction_type returns Journal Entry for 2+ balance sheet counters" do
    counter1 = [nil, nil, nil, nil, "asset", "debit", nil, nil]
    counter2 = [nil, nil, nil, nil, "asset", "credit", nil, nil]
    result = Posting.determine_transaction_type([counter1, counter2], true, @bank)
    assert_equal "Journal Entry", result
  end

  test "determine_transaction_type returns Transfer for exactly 1 balance sheet counter" do
    counter = [nil, nil, nil, nil, "asset", "credit", nil, nil]
    result = Posting.determine_transaction_type([counter], true, @bank)
    assert_equal "Transfer", result
  end

  test "determine_transaction_type returns Deposit for nominal counter when debit" do
    counter = [nil, nil, nil, nil, "income", "credit", nil, nil]
    result = Posting.determine_transaction_type([counter], true, @bank)
    assert_equal "Deposit", result
  end

  test "determine_transaction_type returns Withdrawal for nominal counter when credit" do
    counter = [nil, nil, nil, nil, "expense", "debit", nil, nil]
    result = Posting.determine_transaction_type([counter], false, @bank)
    assert_equal "Withdrawal", result
  end

  # ==================== unlink_receipts (before_destroy) ====================

  test "destroying a posting nullifies its receipts rather than deleting them" do
    receipt = receipts(:linked_receipt)  # already linked to deposit_bank posting
    posting = postings(:deposit_bank)
    assert_equal posting.id, receipt.posting_id

    posting.journal_entry.unpost!
    posting.destroy

    receipt.reload
    assert_nil receipt.posting_id, "Receipt should be unlinked, not deleted"
    assert Receipt.exists?(receipt.id), "Receipt should not be deleted"
  end

  # ==================== link_existing_receipt (after_create)
  # ====================

  test "existing_receipt_id links receipt to newly created posting" do
    receipt = receipts(:unlinked_receipt)
    assert_nil receipt.posting_id

    je = JournalEntry.new(entry_date: Date.current)
    je.save!(validate: false)
    posting = je.postings.create!(
      account: @bank,
      entry_type: :debit,
      amount: 5000,
      currency: "GBP",
      existing_receipt_id: receipt.id
    )

    assert_equal posting.id, receipt.reload.posting_id
  end

  test "existing_receipt_id links multiple receipts when comma-separated" do
    r1 = receipts(:unlinked_receipt)
    r2 = receipts(:second_unlinked_receipt)
    assert_nil r1.posting_id
    assert_nil r2.posting_id

    je = JournalEntry.new(entry_date: Date.current)
    je.save!(validate: false)
    posting = je.postings.create!(
      account: @bank,
      entry_type: :debit,
      amount: 5000,
      currency: "GBP",
      existing_receipt_id: "#{r1.id},#{r2.id}"
    )

    assert_equal posting.id, r1.reload.posting_id
    assert_equal posting.id, r2.reload.posting_id
  end
end
