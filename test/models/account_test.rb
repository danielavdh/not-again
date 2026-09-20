# frozen_string_literal: true

require "test_helper"

class AccountTest < ActiveSupport::TestCase
  def setup
    @bank_gbp = accounts(:bank_gbp)
    @bank_eur = accounts(:bank_eur)
    @income = accounts(:income_sales)
    @expense = accounts(:expenses_general)
    @personal = accounts(:personal_drawings)
  end

  test "valid account with all required attributes" do
    account = Account.new(
      code: "110099",
      name: "New Bank Account",
      account_type: :asset,
      currency: "GBP"
    )
    assert account.valid?, account.errors.full_messages.join(", ")
  end

  test "invalid without code" do
    account = Account.new(name: "Test", account_type: :asset)
    assert_not account.valid?
    assert_includes account.errors[:code], "can\'t be blank"
  end

  test "invalid without name" do
    account = Account.new(code: "110099", account_type: :asset)
    assert_not account.valid?
    assert_includes account.errors[:name], "can\'t be blank"
  end

  test "code must be exactly 6 digits" do
    account = Account.new(code: "12345", name: "Test", account_type: :asset)
    assert_not account.valid?
    assert_includes account.errors[:code], "is the wrong length (should be 6 characters)"
  end

  test "code must start with 1-6" do
    account = Account.new(code: "712345", name: "Test", account_type: :asset)
    assert_not account.valid?
    assert account.errors[:code].any?
  end

  test "code in retained earnings range 3EE9xx is rejected for unlocked accounts" do
    account = Account.new(code: "310901", name: "My Equity", account_type: :equity)
    assert_not account.valid?
    assert account.errors[:code].any? { |e| e.include?("reserved") }
  end

  test "code at start of retained earnings range 3EE900 is rejected" do
    account = Account.new(code: "310900", name: "RE Parent", account_type: :equity)
    assert_not account.valid?
    assert account.errors[:code].any? { |e| e.include?("reserved") }
  end

  test "code at end of retained earnings range 3EE999 is rejected" do
    account = Account.new(code: "310999", name: "RE End", account_type: :equity)
    assert_not account.valid?
    assert account.errors[:code].any? { |e| e.include?("reserved") }
  end

  test "code 3EE9xx is allowed for locked accounts (service-created)" do
    account = Account.new(code: "310902", name: "Retained Earnings EUR", account_type: :equity, currency: "EUR", locked: true)
    account.valid?
    assert_empty account.errors[:code].select { |e| e.include?("reserved") }
  end

  test "code 3EE8xx is not in reserved range and is allowed" do
    account = Account.new(code: "310801", name: "Other Equity", account_type: :equity)
    account.valid?
    assert_empty account.errors[:code].select { |e| e.include?("reserved") }
  end

  test "reserved range error message includes the specific code range" do
    account = Account.new(code: "310942", name: "My Equity", account_type: :equity)
    account.valid?
    error = account.errors[:code].find { |e| e.include?("reserved") }
    assert_includes error, "310900"
    assert_includes error, "310999"
  end

  test "code must be unique" do
    duplicate = Account.new(
      code: @bank_gbp.code,
      name: "Duplicate",
      account_type: :asset,
      currency: "GBP"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:code], "has already been taken"
  end

  test "derives asset type from code starting with 1" do
    account = Account.new(code: "110099", name: "Asset", currency: "GBP")
    account.valid?
    assert account.asset?
  end

  test "derives liability type from code starting with 2" do
    account = Account.new(code: "210099", name: "Liability", currency: "GBP")
    account.valid?
    assert account.liability?
  end

  test "derives equity type from code starting with 3" do
    account = Account.new(code: "310099", name: "Equity", currency: "GBP")
    account.valid?
    assert account.equity?
  end

  test "derives income type from code starting with 4" do
    account = Account.new(code: "410099", name: "Income")
    account.valid?
    assert account.income?
  end

  test "derives expense type from code starting with 5" do
    account = Account.new(code: "510099", name: "Expense")
    account.valid?
    assert account.expense?
  end

  test "derives personal type from code starting with 6" do
    account = Account.new(code: "610099", name: "Personal")
    account.valid?
    assert account.personal?
  end

  test "balance sheet accounts require currency" do
    account = Account.new(code: "110099", name: "Asset", account_type: :asset)
    # Currency should be derived or required
    assert account.asset?
  end

  test "nominal accounts (income/expense/personal) should not have currency" do
    account = Account.new(code: "410099", name: "Income", currency: "GBP")
    account.valid?
    assert_nil account.currency, "Currency should be cleared for nominal accounts"
  end

  test "currency cannot be changed once account has postings" do
    # bank_gbp has postings from fixtures
    @bank_gbp.currency = "EUR"
    assert_not @bank_gbp.valid?
    assert @bank_gbp.errors[:currency].any?
  end

  # A8 (audit-2): retirement used to be a picker-level change only — nothing
  # stopped an account being written with an unknown or retired currency.
  test "a new account cannot be opened in an unknown currency" do
    account = Account.new(code: "110099", name: "Asset", account_type: :asset, currency: "ZZZ")
    assert_not account.valid?
    assert account.errors[:currency].any?
  end

  test "a new account cannot be opened in a retired currency" do
    Currency.create!(code: "ZQX", symbol: "z", active: false)
    account = Account.new(code: "110099", name: "Asset", account_type: :asset, currency: "ZQX")
    assert_not account.valid?
  end

  test "an existing account already holding a retired currency stays valid when nothing currency-related changes" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "110099", name: "Asset", account_type: :asset, currency: "ZQX")
    currency.update!(active: false)

    account.name = "Renamed asset"
    assert account.valid?, "an unrelated edit must not be blocked by a currency retired after the fact"
  end

  test "code prefix cannot be changed once account has postings" do
    # bank_gbp has postings from fixtures
    @bank_gbp.code = "210001"  # Change from 1xx to 2xx
    assert_not @bank_gbp.valid?
    assert @bank_gbp.errors[:code].any?
  end

  # Posts a JE so the given account carries `cents` (debit).
  def give_balance(account, cents)
    je = JournalEntry.new(entry_date: Date.current)
    je.save!(validate: false)
    je.update_column(:posted, true)
    Posting.create!(journal_entry: je, account: account, amount: cents, entry_type: :debit, currency: account.currency)
    Posting.create!(journal_entry: je, account: @income, amount: cents, entry_type: :credit, currency: @income.currency)
  end

  test "an account with a balance cannot be made inactive" do
    acct = Account.create!(code: "110091", name: "Has money", account_type: :asset, currency: "GBP")
    give_balance(acct, 5_000)

    acct.active = false
    assert_not acct.valid?
    assert acct.errors[:active].any?
  end

  test "an account with no postings can be made inactive" do
    acct = Account.create!(code: "110092", name: "Never used", account_type: :asset, currency: "GBP")
    acct.active = false
    assert acct.valid?, acct.errors.full_messages.join(", ")
  end

  test "an account settled back to zero can be made inactive" do
    acct = Account.create!(code: "110093", name: "Used then cleared", account_type: :asset, currency: "GBP")
    give_balance(acct, 5_000)
    # move it back out
    je = JournalEntry.new(entry_date: Date.current)
    je.save!(validate: false)
    je.update_column(:posted, true)
    Posting.create!(journal_entry: je, account: acct, amount: 5_000, entry_type: :credit, currency: "GBP")
    Posting.create!(journal_entry: je, account: @income, amount: 5_000, entry_type: :debit, currency: @income.currency)

    assert acct.balance.zero?
    acct.active = false
    assert acct.valid?, acct.errors.full_messages.join(", ")
  end

  test "reactivating an account is always allowed, balance or not" do
    acct = Account.create!(code: "110094", name: "Back in use", account_type: :asset, currency: "GBP", active: false)
    give_balance(acct, 5_000)

    acct.active = true
    assert acct.valid?, acct.errors.full_messages.join(", ")
  end

  test "code suffix can be changed even with postings" do
    original_code = @bank_gbp.code
    new_code = original_code[0..2] + "999"
    @bank_gbp.code = new_code
    assert @bank_gbp.valid?, @bank_gbp.errors.full_messages.join(", ")
  end

  test "balance calculation for asset account (debit normal)" do
    # From fixtures: bank_gbp has:
    # - deposit_bank: debit 10000
    # - withdrawal_bank: credit 5000
    # - transfer_from: credit 3000
    # - multi_deposit_bank: debit 9500
    # Net: 10000 + 9500 - 5000 - 3000 = 11500 cents = 115.00
    balance = @bank_gbp.balance
    assert_equal 11500, balance
  end

  test "balance calculation for income account (credit normal)" do
    # From fixtures: income_sales has:
    # - deposit_income: credit 10000
    # - multi_deposit_income: credit 10000
    # Net credits: 20000 cents = 200.00
    balance = @income.balance
    assert_equal 20000, balance
  end

  test "balance calculation for expense account (debit normal)" do
    # From fixtures: expenses_general has:
    # - withdrawal_expense: debit 5000
    # Net debits: 5000 cents = 50.00
    balance = @expense.balance
    assert_equal 5000, balance
  end

  test "balance with date range" do
    # Create entry outside current date range
    yesterday = Date.current - 1.day
    je = JournalEntry.new(entry_date: yesterday, posted: true)
    je.save(validate: false)
    Posting.create!(journal_entry: je, account: @bank_gbp, amount: 100000, entry_type: :debit, currency: "GBP")
    Posting.create!(journal_entry: je, account: @income, amount: 100000, entry_type: :credit, currency: "GBP")

    # Balance for today only should exclude yesterday\'s entry
    balance_today = @bank_gbp.balance(start_date: Date.current, end_date: Date.current)
    balance_all = @bank_gbp.balance

    assert balance_all > balance_today
  end

  test "balance excludes unposted entries" do
    # Skip validation by building postings after save
    je = JournalEntry.new(entry_date: Date.current)
    je.save!(validate: false)
    je.update_column(:posted, false)
    Posting.create!(journal_entry: je, account: @bank_gbp, amount: 999900, entry_type: :debit, currency: "GBP")
    Posting.create!(journal_entry: je, account: @income, amount: 999900, entry_type: :credit, currency: "GBP")

    balance = @bank_gbp.balance
    # Should not include the 9999.00 from unposted entry
    assert balance < 999900
  end

  test "balances_for returns hash of account_id to balance" do
    balances = Account.balances_for([@bank_gbp.id, @income.id, @expense.id])

    assert_kind_of Hash, balances
    assert balances.key?(@bank_gbp.id)
    assert balances.key?(@income.id)
    assert balances.key?(@expense.id)
  end

  test "balances_for returns empty hash for empty array" do
    balances = Account.balances_for([])
    assert_equal({}, balances)
  end

  test "balances_for handles accounts with no postings" do
    new_account = Account.create!(code: "110088", name: "Empty Account", account_type: :asset, currency: "GBP")
    balances = Account.balances_for([new_account.id])

    # Account with no postings should not be in results or have 0 balance
    assert_equal 0, balances[new_account.id].to_i
  end

  test "balances_for returns correct signed balance using enum-safe entry_type integers" do
    # bank_gbp (asset, debit-normal): debit 10000 + 9500, credit 5000 + 3000 =
    # +11500
    # income_sales (income, credit-normal): credit 10000 + 10000 = +20000
    # expenses_general (expense, debit-normal): debit 5000 = +5000
    balances = Account.balances_for([@bank_gbp.id, @income.id, @expense.id])
    assert_equal 11500, balances[@bank_gbp.id]
    assert_equal 20000, balances[@income.id]
    assert_equal 5000,  balances[@expense.id]
  end

  test "active scope excludes inactive accounts" do
    active_accounts = Account.active
    inactive = accounts(:inactive_account)

    assert_not_includes active_accounts, inactive
  end

  test "by_type scope filters by account type" do
    assets = Account.by_type(:asset)

    assert assets.all?(&:asset?)
  end

  test "leaf_accounts excludes parent accounts" do
    parent = accounts(:parent_account)
    child = @bank_gbp
    child.update!(parent: parent)

    leaves = Account.leaf_accounts

    assert_not_includes leaves, parent
  end

  test "debit_normal? returns true for asset accounts" do
    assert @bank_gbp.debit_normal?
  end

  test "debit_normal? returns true for expense accounts" do
    assert @expense.debit_normal?
  end

  test "debit_normal? returns true for personal accounts" do
    assert @personal.debit_normal?
  end

  test "#balance and .balances_for agree on the sign of a personal account" do
    je = JournalEntry.new(entry_date: Date.current, memo: "drawing")
    je.postings.build(account: @personal, amount: 5_000, entry_type: :debit)
    je.postings.build(account: @bank_gbp, amount: 5_000, entry_type: :credit, currency: "GBP")
    je.posted = true
    je.save!

    assert_equal 5_000, @personal.balance,
      "a drawing is money out — a personal account reads debit-normal, like an expense"
    assert_equal 5_000, Account.balances_for([@personal.id])[@personal.id]
  end

  test "debit_normal? returns false for liability accounts" do
    liability = accounts(:accounts_payable)
    assert_not liability.debit_normal?
  end

  test "debit_normal? returns false for income accounts" do
    assert_not @income.debit_normal?
  end

  test "deduction_percentage is valid when nil" do
    @expense.deduction_percentage = nil
    assert @expense.valid?
  end

  test "deduction_percentage is valid within 1-99" do
    @expense.deduction_percentage = 40
    assert @expense.valid?
  end

  test "deduction_percentage is invalid when 0" do
    @expense.deduction_percentage = 0
    assert_not @expense.valid?
    assert @expense.errors[:deduction_percentage].any?
  end

  test "deduction_percentage is invalid when 100" do
    @expense.deduction_percentage = 100
    assert_not @expense.valid?
    assert @expense.errors[:deduction_percentage].any?
  end

  test "deduction_percentage is invalid when negative" do
    @expense.deduction_percentage = -10
    assert_not @expense.valid?
    assert @expense.errors[:deduction_percentage].any?
  end
end


