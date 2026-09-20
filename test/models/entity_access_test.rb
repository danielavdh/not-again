# frozen_string_literal: true

require "test_helper"

class EntityAccessTest < ActiveSupport::TestCase
  # Fixtures:
  # entities: personal(01), spouse(03), daughter(04), family_biz(10),
  # standalone(05)
  # admins: one(entity_code 01), two(entity_code 10), sudo
  # admin_entities: one→personal, one→spouse, two→family_biz, two→daughter

  # --- Admin#entity_codes ---

  test "admin one sees directly assigned entities 01 and 03" do
    admin = admins(:one)
    codes = admin.entity_codes.sort
    assert_equal ["01", "03"], codes
  end

  test "admin two sees directly assigned entities 04 and 10" do
    admin = admins(:two)
    codes = admin.entity_codes.sort
    assert_equal ["04", "10"], codes
  end

  # --- Admin#accessible_accounts ---

  test "admin one can access accounts from entities 01 and 03" do
    admin = admins(:one)
    account_codes = admin.accessible_accounts.pluck(:code)
    assert account_codes.include?("101001")  # entity 01
  end

  test "admin two can access accounts from entities 04 and 10" do
    admin = admins(:two)
    account_codes = admin.accessible_accounts.pluck(:code)
    assert account_codes.include?("110001")  # entity 10
    assert account_codes.include?("104001")  # entity 04
  end

  test "admin two cannot access entity 01 accounts" do
    admin = admins(:two)
    refute admin.accessible_accounts.where(code: "101001").exists?
  end

  test "sudo with no entities sees all accounts" do
    admin = admins(:sudo)
    assert_equal Account.count, admin.accessible_accounts.count
  end

  # --- Admin#owns_account? ---

  test "admin one owns entity 01 accounts" do
    admin = admins(:one)
    boss_bank = accounts(:boss_bank)
    assert admin.owns_account?(boss_bank)
  end

  # --- postings_same_entity validation ---

  test "same-entity posting is allowed" do
    je = JournalEntry.new(
      entry_date: Date.current,
      memo: "Same entity"
    )
    je.postings.build(
      account_id: accounts(:bank_gbp).id,  # entity 10
      amount: 10000, entry_type: :debit, currency: "GBP"
    )
    je.postings.build(
      account_id: accounts(:bank_eur).id,  # entity 10
      amount: 10000, entry_type: :credit, currency: "EUR"
    )
    je.valid?
    refute je.errors[:base].any? { |e| e.include?("entity") },
           "Should allow posting within same entity"
  end

  test "cross-entity posting is rejected" do
    je = JournalEntry.new(
      entry_date: Date.current,
      memo: "Cross-entity posting"
    )
    je.postings.build(
      account_id: accounts(:boss_bank).id,  # entity 01
      amount: 10000, entry_type: :debit, currency: "GBP"
    )
    je.postings.build(
      account_id: accounts(:bank_gbp).id,  # entity 10
      amount: 10000, entry_type: :credit, currency: "GBP"
    )
    refute je.valid?
    assert je.errors[:base].any?, "cross-entity journal entry must be rejected"
  end

  # --- AdminEntity ---

  test "cannot assign same entity twice to same admin" do
    admin = admins(:one)
    entity = entities(:personal)
    duplicate = AdminEntity.new(admin: admin, entity: entity)
    refute duplicate.valid?
    assert duplicate.errors[:admin_id].present?
  end
end