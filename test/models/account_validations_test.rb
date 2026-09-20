# frozen_string_literal: true

require "test_helper"

# Account rules not covered in account_test.rb: parent_cannot_be_grandparent,
# entity_code_matches_creator, inherit_parent_currency_for_balance_accounts,
# clear_currency_for_nominal_accounts, unmapped_for_tax.
class AccountValidationsTest < ActiveSupport::TestCase
  setup do
    @parent = accounts(:parent_account) # 110000, asset, GBP, no parent
    @bank   = accounts(:bank_gbp)       # 110001, asset, GBP, no parent
  end

  # ==================== parent_cannot_be_grandparent ====================

  test "cannot select a two-level-deep parent (max 2 levels)" do
    # parent_account (110000) is a root; bank_gbp (110001) can be a child of it.
    # bank_gbp cannot itself become a parent when it already has a parent.
    child = Account.create!(
      code: "110003", name: "Child Account", account_type: :asset,
      currency: "GBP", parent: @parent
    )

    grandchild = Account.new(
      code: "110004", name: "Grandchild Account", account_type: :asset,
      currency: "GBP", parent: child
    )

    assert_not grandchild.valid?
    assert grandchild.errors[:parent_id].any? { |e| e.include?("max 2 levels") }
  end

  test "valid with one level of parent" do
    child = Account.new(
      code: "110005", name: "Child", account_type: :asset,
      currency: "GBP", parent: @parent
    )
    assert child.valid?, child.errors.full_messages.join(", ")
  end

  test "valid with no parent" do
    root = Account.new(
      code: "110006", name: "Root", account_type: :asset, currency: "GBP"
    )
    assert root.valid?, root.errors.full_messages.join(", ")
  end

  # ==================== inherit_parent_currency_for_balance_accounts
  # ====================

  test "balance account inherits parent currency when parent has one" do
    child = Account.new(
      code: "110007", name: "Child Bank", account_type: :asset,
      parent: @parent   # parent has currency: GBP
    )
    child.valid?
    assert_equal "GBP", child.currency
  end

  test "nominal account does not inherit parent currency" do
    income_parent = Account.create!(
      code: "410000", name: "Income Parent", account_type: :income
    )
    child = Account.new(
      code: "410003", name: "Child Income", account_type: :income,
      parent: income_parent
    )
    child.valid?
    assert_nil child.currency
  end

  # ==================== clear_currency_for_nominal_accounts
  # ====================

  test "currency is cleared on save for income accounts" do
    account = Account.new(
      code: "410004", name: "Sales Extra", account_type: :income, currency: "GBP"
    )
    account.valid?
    assert_nil account.currency
  end

  test "currency is cleared on save for expense accounts" do
    account = Account.new(
      code: "510010", name: "Extra Expense", account_type: :expense, currency: "EUR"
    )
    account.valid?
    assert_nil account.currency
  end

  # ==================== entity_code_matches_creator ====================

  test "valid when creating admin's entity code matches account code" do
    admin = admins(:two) # entity_code: "10"
    # Entity 10 accounts have code starting with X10XXX
    account = Account.new(
      code: "410005", name: "New Income", account_type: :income
    )
    account.creating_admin = admin
    assert account.valid?, account.errors.full_messages.join(", ")
  end

  test "invalid when creating admin's entity code does not match" do
    admin = admins(:two) # entity_code: "10"
    account = Account.new(
      code: "401005", name: "Wrong Entity Income", account_type: :income
    )
    account.creating_admin = admin
    assert_not account.valid?
    assert account.errors[:code].any? { |e| e.include?("entity codes") }
  end

  test "skips entity code check when no creating_admin set" do
    account = Account.new(
      code: "410006", name: "No Admin", account_type: :income
    )
    assert account.valid?, account.errors.full_messages.join(", ")
  end

  # ==================== unmapped_for_tax ====================

  test "unmapped_for_tax returns leaf income/expense with no tax_category_key" do
    entity = entities(:family_biz) # code: "10"
    results = Account.unmapped_for_tax(entity_codes: [entity.code])

    assert results.any?
    results.each do |acct|
      assert acct.income? || acct.expense?, "Expected income or expense, got #{acct.account_type}"
      assert acct.tax_category_key.blank?
      assert_equal entity.code, acct.code[1, 2]
    end
  end

  # Unmapped means "belongs to no return this entity files", not "has no key".
  test "unmapped_for_tax excludes accounts assigned to a return the entity files" do
    entity  = entities(:family_biz)
    entity.update!(tax_schemes: [ "gb_self_employment" ])
    # Subscribing creates the group; the group is what claims the account.
    entity.report_groups.find_or_create_by!(tax_scheme: "gb_self_employment") { |g| g.name = "se" }
    account = accounts(:income_sales)
    account.update!(tax_scheme: "gb_self_employment", tax_category_key: "sales_income")

    results = Account.unmapped_for_tax(entity_codes: [entity.code])
    assert results.none? { |a| a.id == account.id }
  ensure
    account.update!(tax_scheme: nil, tax_category_key: nil)
  end

  # A key on its own is not an assignment — tax_category_combined needs both.
  test "a key without a scheme is still unmapped" do
    entity  = entities(:family_biz)
    account = accounts(:income_sales)
    account.update!(tax_category_key: "revenue", tax_scheme: nil)

    results = Account.unmapped_for_tax(entity_codes: [entity.code])
    assert results.any? { |a| a.id == account.id }
  ensure
    account.update!(tax_category_key: nil)
  end

  # The stranded case: tagged to a scheme whose GROUP is gone. It has no assign
  # page of its own any more, so if this did not surface it, nothing would.
  test "unmapped_for_tax surfaces an account whose report group is gone" do
    entity  = entities(:family_biz)
    entity.update!(tax_schemes: [ "gb_property" ])
    entity.report_groups.where(tax_scheme: "gb_self_employment").destroy_all
    account = accounts(:income_sales)
    account.update!(tax_scheme: "gb_self_employment", tax_category_key: "sales_income")

    results = Account.unmapped_for_tax(entity_codes: [entity.code])
    assert results.any? { |a| a.id == account.id }
  ensure
    account.update!(tax_scheme: nil, tax_category_key: nil)
  end

  # A group that outlived its subscription because it has reports still needs
  # its accounts: every figure in that report is recomputed from them, so
  # offering them elsewhere would let a reassignment empty it silently.
  test "unmapped_for_tax leaves alone an account whose group survived on its reports" do
    entity = entities(:family_biz)
    entity.update!(tax_schemes: [])
    group  = entity.report_groups.create!(name: "kept", tax_scheme: "gb_property")
    group.reports.create!(name: "Q1", start_date: Date.new(2026, 4, 6),
                          end_date: Date.new(2026, 7, 5))
    account = accounts(:income_sales)
    account.update!(tax_scheme: "gb_property", tax_category_key: "rent_income")

    results = Account.unmapped_for_tax(entity_codes: [entity.code])
    assert results.none? { |a| a.id == account.id },
           "still feeding a report that is recomputed from it"
  ensure
    account.update!(tax_scheme: nil, tax_category_key: nil)
  end

  test "unmapped_for_tax returns empty for blank entity_codes" do
    assert_empty Account.unmapped_for_tax(entity_codes: [])
  end

  test "unmapped_for_tax excludes balance sheet accounts" do
    entity  = entities(:family_biz)
    results = Account.unmapped_for_tax(entity_codes: [entity.code])

    assert results.none?(&:balance_account?)
  end
end
