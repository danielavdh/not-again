# frozen_string_literal: true

require "test_helper"

class PostingTest < ActiveSupport::TestCase
  def setup
    @bank_gbp = accounts(:bank_gbp)
    @bank_eur = accounts(:bank_eur)
    @income = accounts(:income_sales)
    @expense = accounts(:expenses_general)
    @journal_entry = journal_entries(:draft_entry)
  end

  test "valid posting with all required attributes" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @bank_gbp,
      amount: 10000,
      entry_type: :debit,
      currency: "GBP"
    )
    assert posting.valid?, posting.errors.full_messages.join(", ")
  end

  test "invalid without account" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      amount: 10000,
      entry_type: :debit,
      currency: "GBP"
    )
    assert_not posting.valid?
    assert_includes posting.errors[:account_id], "must be selected"
  end

  test "invalid without entry_type" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @bank_gbp,
      amount: 10000,
      currency: "GBP"
    )
    assert_not posting.valid?
    assert_includes posting.errors[:entry_type], "can\'t be blank"
  end

  test "invalid without amount" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @bank_gbp,
      entry_type: :debit,
      currency: "GBP"
    )
    assert_not posting.valid?
    assert posting.errors[:amount_display].any?
  end

  test "invalid with zero amount" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @bank_gbp,
      amount: 0,
      entry_type: :debit,
      currency: "GBP"
    )
    assert_not posting.valid?
    assert posting.errors[:amount_display].any?
  end

  test "zero amount is allowed on a closing entry (break-even retained-earnings leg)" do
    posting = Posting.new(
      journal_entry: journal_entries(:closing_entry_fy2024),
      account: accounts(:re_gbp_entity10),
      amount: 0,
      entry_type: :credit,
      currency: "GBP"
    )
    assert posting.valid?, posting.errors.full_messages.join(", ")
  end

  test "invalid with negative amount before normalization" do
    # Note: normalize_negative_amounts should convert this
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @bank_gbp,
      amount: -10000,
      entry_type: :debit,
      currency: "GBP"
    )
    posting.valid?
    # After normalization, amount should be positive
    assert_equal 10000, posting.amount
  end

  test "set_currency_from_account overrides currency for balance accounts" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @bank_gbp,
      amount: 10000,
      entry_type: :debit,
      currency: "EUR"  # deliberately wrong
    )
    posting.valid?
    # Callback should have corrected it
    assert_equal "GBP", posting.currency
    assert posting.valid?
  end

  test "balance account posting gets currency from account even when blank" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @bank_gbp,
      amount: 10000,
      entry_type: :debit
      # no currency set
    )
    posting.valid?
    assert_equal "GBP", posting.currency
  end

  test "currency cleared for nominal accounts" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @income,
      amount: 10000,
      entry_type: :credit,
      currency: "GBP"  # set but should be cleared
    )
    posting.valid?
    assert_nil posting.currency
  end
  
  test "currency can differ for income accounts" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @income,  # No fixed currency
      amount: 10000,
      entry_type: :credit,
      currency: "EUR"
    )
    # Should be valid - income accounts don\'t have currency restriction
    assert posting.valid?, posting.errors.full_messages.join(", ")
  end

  test "normalize_negative_amounts converts negative debit to positive credit" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @income,
      amount: -5000,
      entry_type: :debit,
      currency: "GBP"
    )
    posting.valid?

    assert_equal 5000, posting.amount
    assert posting.credit?
  end

  test "normalize_negative_amounts converts negative credit to positive debit" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @income,
      amount: -5000,
      entry_type: :credit,
      currency: "GBP"
    )
    posting.valid?

    assert_equal 5000, posting.amount
    assert posting.debit?
  end

  test "normalize_negative_amounts does not affect positive amounts" do
    posting = Posting.new(
      journal_entry: @journal_entry,
      account: @income,
      amount: 5000,
      entry_type: :debit,
      currency: "GBP"
    )
    posting.valid?

    assert_equal 5000, posting.amount
    assert posting.debit?
  end

  test "amount_display= converts decimal string to cents" do
    posting = Posting.new
    posting.amount_display = "123.45"

    assert_equal 12345, posting.amount
  end

  test "amount_display= handles comma as decimal separator" do
    posting = Posting.new
    posting.amount_display = "123,45"

    assert_equal 12345, posting.amount
  end

  test "amount_display= handles thousands separator" do
    posting = Posting.new
    posting.amount_display = "1,234.56"

    assert_equal 123456, posting.amount
  end

  test "amount_display= handles negative values" do
    posting = Posting.new
    posting.amount_display = "-50.00"

    assert_equal(-5000, posting.amount)
  end

  test "amount_display returns decimal from cents" do
    posting = Posting.new(amount: 12345)

    assert_equal 123.45, posting.amount_display
  end

  test "amount_display returns nil for nil amount" do
    posting = Posting.new

    assert_nil posting.amount_display
  end

  test "amount_display_for returns positive when entry_type matches expected" do
    posting = Posting.new(amount: 5000, entry_type: :debit)

    result = posting.amount_display_for("debit")
    assert_equal 50.0, result
  end

  test "amount_display_for returns negative when entry_type differs from expected" do
    posting = Posting.new(amount: 5000, entry_type: :credit)

    result = posting.amount_display_for("debit")
    assert_equal(-50.0, result)
  end

  test "amount_display_for returns nil for zero amount" do
    posting = Posting.new(amount: 0, entry_type: :debit)

    assert_nil posting.amount_display_for("debit")
  end

  test "amount_display_for returns nil for nil amount" do
    posting = Posting.new(entry_type: :debit)

    assert_nil posting.amount_display_for("debit")
  end

  test "amount_display_formatted returns locale-formatted string" do
    posting = Posting.new(amount: 123456, entry_type: :debit)

    formatted = posting.amount_display_formatted
    # Should be something like "1,234.56" or "1.234,56"
    assert_match(/1.*234.*56/, formatted)
  end

  test "amount_display_formatted with expected_type shows sign" do
    posting = Posting.new(amount: 5000, entry_type: :credit)

    formatted = posting.amount_display_formatted("debit")
    assert formatted.start_with?("-"), "Expected negative sign for mismatched type"
  end

  test "amount_display_formatted returns nil for nil amount" do
    posting = Posting.new

    assert_nil posting.amount_display_formatted
  end

  test "debit scope returns only debit postings" do
    debits = Posting.debit

    assert debits.all?(&:debit?)
  end

  test "credit scope returns only credit postings" do
    credits = Posting.credit

    assert credits.all?(&:credit?)
  end

  test "for_account scope filters by account" do
    postings = Posting.for_account(@bank_gbp.id)

    postings.each do |posting|
      assert_equal @bank_gbp.id, posting.account_id
    end
  end

  test "by_currency scope filters by currency" do
    postings = Posting.by_currency("GBP")

    postings.each do |posting|
      assert_equal "GBP", posting.currency
    end
  end

  test "ledger_base_scope returns postings for account" do
    scope = Posting.ledger_base_scope(@bank_gbp.id)

    scope.each do |posting|
      assert_equal @bank_gbp.id, posting.account_id
    end
  end

  test "ledger_base_scope only includes posted entries" do
    scope = Posting.ledger_base_scope(@bank_gbp.id)

    scope.each do |posting|
      assert posting.journal_entry.posted?
    end
  end

  test "ledger_base_scope filters by date range" do
    start_date = Date.current
    end_date = Date.current

    scope = Posting.ledger_base_scope(@bank_gbp.id, start_date: start_date, end_date: end_date)

    scope.includes(:journal_entry).each do |posting|
      assert posting.journal_entry.entry_date >= start_date
      assert posting.journal_entry.entry_date <= end_date
    end
  end

  test "ledger_data_from_scope returns named rows, not bare arrays" do
    scope = Posting.ledger_base_scope(@bank_gbp.id)
    data = Posting.ledger_data_from_scope(scope, @bank_gbp)

    assert_kind_of Array, data
    assert data.any?, "the fixture bank account should have ledger lines"
    data.each do |row|
      assert_kind_of Posting::LedgerRow, row
      assert_equal 12, row.length
      # Still indexable by position — the CSV export and the running-balance
      # calculation were written against the old array shape.
      assert_equal row.debit, row[6]
      assert_equal row.amount, row[7]
      assert_equal row.posting_id, row[9]
    end
  end

  test "ledger_data_from_scope sets debit correctly from enum-cast entry_type" do
    # bank_gbp has both debit (deposit) and credit (withdrawal, transfer)
    # postings
    scope = Posting.ledger_base_scope(@bank_gbp.id)
    data = Posting.ledger_data_from_scope(scope, @bank_gbp)

    assert data.any?(&:debit?),  "Expected at least one debit posting"
    assert data.any? { |row| !row.debit? }, "Expected at least one credit posting"
  end

  test "a ledger row falls back to its counter account's currency" do
    scope = Posting.ledger_base_scope(@bank_gbp.id)
    row = Posting.ledger_data_from_scope(scope, @bank_gbp).first

    assert_equal row.currency, row.display_currency,
      "a posting with its own currency keeps it"

    row.currency = nil
    expected = row.counter_accounts.size == 1 ? row.counter_accounts.first[7] : nil
    assert_equal expected, row.display_currency,
      "without one it takes the sole counter account's — that is how a nominal line gets a currency"
  end

  test "determine_transaction_type returns Transfer for asset counter account" do
    # ca[4] = account_type as string (Rails 8.1 applies enum casting in pluck on
    # joined tables)
    counter_accounts = [
      [1, 2, "140001", "Daughter Bank", "asset", "debit", 10000, "GBP"]
    ]

    result = Posting.determine_transaction_type(counter_accounts, true, @bank_gbp)
    assert_equal "Transfer", result
  end

  test "determine_transaction_type returns Transfer for equity counter account" do
    counter_accounts = [
      [1, 2, "310001", "Capital", "equity", "credit", 10000, "GBP"]
    ]

    result = Posting.determine_transaction_type(counter_accounts, false, @bank_gbp)
    assert_equal "Transfer", result
  end

  test "determine_transaction_type returns Transfer for liability counter account" do
    counter_accounts = [
      [1, 2, "210001", "Payable", "liability", "debit", 10000, "GBP"]
    ]

    result = Posting.determine_transaction_type(counter_accounts, false, @bank_gbp)
    assert_equal "Transfer", result
  end

  test "determine_transaction_type returns Deposit for debit with income counter" do
    counter_accounts = [
      [1, 2, "410001", "Sales", "income", "credit", 10000, "GBP"]
    ]

    result = Posting.determine_transaction_type(counter_accounts, true, @bank_gbp)
    assert_equal "Deposit", result
  end

  test "determine_transaction_type returns Withdrawal for credit with expense counter" do
    counter_accounts = [
      [1, 2, "510001", "Expenses", "expense", "debit", 10000, "GBP"]
    ]

    result = Posting.determine_transaction_type(counter_accounts, false, @bank_gbp)
    assert_equal "Withdrawal", result
  end

  test "determine_transaction_type returns Unknown for empty counter accounts" do
    result = Posting.determine_transaction_type([], true, @bank_gbp)
    assert_equal "Unknown", result
  end

  test "balance_account_edit_type returns deposit for debit entry_type" do
    # ca[5] = entry_type as string (enum-cast pluck)
    counter_accounts = [[1, 2, "110001", "Bank", Account.account_types[:asset], "debit", 10000, "GBP"]]
    assert_equal "deposit", Posting.balance_account_edit_type(counter_accounts)
  end

  test "balance_account_edit_type returns withdrawal for credit entry_type" do
    counter_accounts = [[1, 2, "110001", "Bank", Account.account_types[:asset], "credit", 10000, "GBP"]]
    assert_equal "withdrawal", Posting.balance_account_edit_type(counter_accounts)
  end

  test "balance_account_edit_type returns nil for empty counter accounts" do
    assert_nil Posting.balance_account_edit_type([])
  end

end
