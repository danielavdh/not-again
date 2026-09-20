# frozen_string_literal: true

require "test_helper"

# Validation rules not covered in journal_entry_test.rb:
# single_balance_account_with_nominals, postings_same_group,
# transfer?/deposit?/withdrawal?, cross_currency_transfer?,
# implied_exchange_rate, display_currency, the for_entity scope.
class JournalEntryValidationsTest < ActiveSupport::TestCase
  setup do
    @bank_gbp    = accounts(:bank_gbp)
    @bank_eur    = accounts(:bank_eur)
    @income      = accounts(:income_sales)
    @expense     = accounts(:expenses_general)
    @boss_bank   = accounts(:boss_bank)       # entity 01
    @daughter_bank = accounts(:daughter_bank) # entity 04
  end

  # ==================== single_balance_account_with_nominals
  # ====================

  test "valid with two balance accounts and no nominals (transfer)" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit,  currency: "GBP")
    je.postings.build(account: @bank_eur, amount: 11500, entry_type: :credit, currency: "EUR")
    assert je.valid?, je.errors.full_messages.join(", ")
  end

  test "invalid with two balance accounts when a nominal account is also present" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp,  amount: 10000, entry_type: :debit,  currency: "GBP")
    je.postings.build(account: @bank_eur,  amount: 5000,  entry_type: :credit, currency: "GBP")
    je.postings.build(account: @income,    amount: 5000,  entry_type: :credit, currency: "GBP")

    assert_not je.valid?
    assert je.errors[:base].any?
  end

  # The shape a private-use split (or VAT booked to a nominal) takes: one bank
  # leg, two nominal legs. One balance account → allowed.
  test "valid with one balance account and two nominals (a split expense)" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :credit, currency: "GBP")
    je.postings.build(account: @expense,  amount: 6000,  entry_type: :debit)
    je.postings.build(account: accounts(:expenses_fees), amount: 4000, entry_type: :debit)
    assert je.valid?, je.errors.full_messages.join(", ")
  end

  # A three-account entry touching the P&L with two balance legs — a loan
  # repayment split into principal and interest — is refused: one balance
  # account when nominals are present.
  test "invalid with two balance accounts and a nominal (loan-repayment shape)" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :credit, currency: "GBP")
    je.postings.build(account: accounts(:accounts_payable), amount: 8000, entry_type: :debit, currency: "GBP")
    je.postings.build(account: @expense, amount: 2000, entry_type: :debit)
    assert_not je.valid?
    assert je.errors[:base].any?
  end

  # A multi-currency entry balances per currency, not in total. A GBP side that
  # is short is refused even though a naive total would tie out.
  test "an entry whose GBP side does not balance is refused" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit,  currency: "GBP")
    je.postings.build(account: @bank_gbp, amount:  6000, entry_type: :credit, currency: "GBP")
    je.postings.build(account: @bank_eur, amount:  4000, entry_type: :credit, currency: "EUR")
    assert_not je.balanced?
    assert_not je.save
  end

  # ==================== postings_same_group ====================

  test "postings_same_group rejects a journal entry crossing groups, even for sudo" do
    sudo = admins(:sudo)
    Current.session = Session.create!(admin: sudo)

    # @bank_gbp is entity 10, @boss_bank is entity 01 — both ungrouped, so each
    # is its own group: crossing them crosses groups.
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp,  amount: 10000, entry_type: :debit,  currency: "GBP")
    je.postings.build(account: @boss_bank, amount: 10000, entry_type: :credit, currency: "GBP")

    assert_not je.valid?, "cross-group journal entry should be invalid"
    assert je.errors[:base].any?, "expected a base error for the cross-group entry"
  ensure
    Current.reset
  end

  test "postings_same_group allows crossing entities that share a consolidation group" do
    sudo = admins(:sudo)
    Current.session = Session.create!(admin: sudo)

    group = EntityGroup.create!(name: "Household")
    entities(:personal).update!(entity_group: group)   # entity 01
    entities(:family_biz).update!(entity_group: group) # entity 10

    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp,  amount: 10000, entry_type: :debit,  currency: "GBP") # entity 10
    je.postings.build(account: @boss_bank, amount: 10000, entry_type: :credit, currency: "GBP") # entity 01

    assert je.valid?, je.errors.full_messages.join(", ")
  ensure
    Current.reset
  end

  test "postings_same_entity passes when all postings belong to one entity" do
    admin = admins(:two)
    Current.session = Session.create!(admin: admin)

    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :debit,  currency: "GBP")
    je.postings.build(account: @income,   amount: 10000, entry_type: :credit, currency: "GBP")

    assert je.valid?, je.errors.full_messages.join(", ")
  ensure
    Current.reset
  end

  # ==================== for_entity scope ====================

  test "for_entity scope returns entries that have a posting for the given entity" do
    entity = entities(:family_biz)
    entries = JournalEntry.for_entity(entity)

    assert entries.any?, "Expected at least one journal entry for family_biz"
    entries.each do |je|
      codes = je.postings.joins(:account).pluck("accounts.code")
      assert codes.any? { |c| c.start_with?("_#{entity.code}") || c[1, 2] == entity.code },
             "Entry #{je.id} has no posting for entity #{entity.code}"
    end
  end

  # ==================== transfer? / deposit? / withdrawal? ====================

  test "transfer? returns true for 2-posting entry between balance accounts" do
    je = journal_entries(:posted_transfer)
    assert je.transfer?
  end

  test "deposit? returns true when balance account posting is a debit" do
    je = journal_entries(:posted_deposit)
    assert je.deposit?(@bank_gbp)
  end

  test "withdrawal? returns true when balance account posting is a credit" do
    je = journal_entries(:posted_withdrawal)
    assert je.withdrawal?(@bank_gbp)
  end

  test "deposit? returns false for the credit side" do
    je = journal_entries(:posted_deposit)
    assert_not je.deposit?(@income)
  end

  # ==================== cross_currency_transfer? ====================

  test "cross_currency_transfer? returns true for two different-currency balance accounts" do
    je = JournalEntry.new(entry_date: Date.current)
    je.from_account_id = @bank_gbp.id
    je.to_account_id   = @bank_eur.id

    assert je.cross_currency_transfer?
  end

  test "cross_currency_transfer? returns false when same currency" do
    bank_gbp_two = accounts(:bank_gbp_two)
    je = JournalEntry.new(entry_date: Date.current)
    je.from_account_id = @bank_gbp.id
    je.to_account_id   = bank_gbp_two.id

    assert_not je.cross_currency_transfer?
  end

  test "cross_currency_transfer? returns false when no from/to set" do
    je = JournalEntry.new(entry_date: Date.current)
    assert_not je.cross_currency_transfer?
  end

  # ==================== implied_exchange_rate ====================

  test "implied_exchange_rate computes target / transfer" do
    je = JournalEntry.new(entry_date: Date.current)
    je.transfer_amount = 10000
    je.target_amount   = 11500

    assert_in_delta 1.15, je.implied_exchange_rate, 0.000001
  end

  test "implied_exchange_rate returns nil when transfer_amount is zero" do
    je = JournalEntry.new(entry_date: Date.current)
    je.transfer_amount = 0
    je.target_amount   = 11500

    assert_nil je.implied_exchange_rate
  end

  test "implied_exchange_rate returns nil when target_amount is nil" do
    je = JournalEntry.new(entry_date: Date.current)
    je.transfer_amount = 10000

    assert_nil je.implied_exchange_rate
  end

  # ==================== display_currency ====================

  test "display_currency returns the currency when all postings share one" do
    je = journal_entries(:posted_deposit)
    # Deposit is single-currency GBP
    assert_equal "GBP", je.display_currency
  end

  test "display_currency returns nil for cross-currency entry" do
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: @bank_gbp, amount: 10000, entry_type: :credit, currency: "GBP")
    je.postings.build(account: @bank_eur, amount: 11500, entry_type: :debit,  currency: "EUR")
    assert_nil je.display_currency
  end
end
