# frozen_string_literal: true

require "test_helper"

# Copying a VAT entry has to bring back the GROSS, as typed, and the code —
# then re-derive at the copy's own date. The amount stored is the net, so a copy
# that carried the stored amount would quietly shrink by the VAT each time.
class AccountsVatCopyTest < ActionDispatch::IntegrationTest
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    entities(:family_biz).update!(tax_schemes: [ "gb_vat" ])
    sign_in_as(admins(:two))
    @bank = accounts(:bank_gbp)
    @code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: Date.new(2026, 5, 1))

    @je = JournalEntry.new(entry_date: Date.new(2026, 5, 1), memo: "kit", posted: true)
    @je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                       amount: 12_000, tax_code_id: @code.id)
    @je.derive_tax_legs
    @je.postings.build(account: @bank, entry_type: :credit, amount: 12_000, currency: "GBP")
    @je.save!
  end

  test "a copy comes back with the gross in the amount field, not the net" do
    get copy_withdrawal_account_path(@bank, journal_entry_id: @je.id)

    assert_response :success
    # 120.00 is the figure the user typed and the statement shows. 100.00 is
    # the stored net — a copy carrying that would shrink by the VAT each time.
    assert_select "input.posting-amount[value='120.00']"
    assert_select "input.posting-amount[value='100.00']", count: 0
  end

  test "a copy keeps the VAT code" do
    get copy_withdrawal_account_path(@bank, journal_entry_id: @je.id)

    assert_select "select.posting-tax-code option[selected]", text: @code.display_name
  end

  # The account remembers the code it was last used with, so the common case
  # needs no second choice. A convenience only — the posting carries its own
  # code — but it must not be settable to a code the business cannot use.
  test "the account remembers a code it was used with" do
    patch save_default_tax_code_account_path(accounts(:expenses_general)),
          params: { default_tax_code_id: @code.id }

    assert_response :success
    assert_equal @code.id, accounts(:expenses_general).reload.default_tax_code_id
  end

  test "a blank clears it, which is how a wrong guess is undone" do
    accounts(:expenses_general).update!(default_tax_code: @code)

    patch save_default_tax_code_account_path(accounts(:expenses_general)),
          params: { default_tax_code_id: "" }

    assert_response :success
    assert_nil accounts(:expenses_general).reload.default_tax_code_id
  end

  # A private 6xx account remembered a purchase code in the real books, and then
  # offered it on the private half of every split — where the model refuses it.
  # A default the account could never use is worse than no default.
  test "a private account cannot remember a VAT code" do
    patch save_default_tax_code_account_path(accounts(:personal_drawings)),
          params: { default_tax_code_id: @code.id }

    assert_response :unprocessable_entity
    assert_nil accounts(:personal_drawings).reload.default_tax_code_id
  end

  test "a balance-sheet account cannot remember a VAT code" do
    patch save_default_tax_code_account_path(accounts(:accounts_payable)),
          params: { default_tax_code_id: @code.id }

    assert_response :unprocessable_entity
    assert_nil accounts(:accounts_payable).reload.default_tax_code_id
  end

  # Right code, wrong way round: a sale code on an expense would derive its leg
  # into the output-VAT account and report tax owed on money spent.
  test "an income account cannot remember a purchase code" do
    sale = TaxCode.resolve(scheme: "gb_vat", key: "sale_standard", on: Date.new(2026, 5, 1))

    patch save_default_tax_code_account_path(accounts(:income_sales)),
          params: { default_tax_code_id: @code.id }
    assert_response :unprocessable_entity

    patch save_default_tax_code_account_path(accounts(:income_sales)),
          params: { default_tax_code_id: sale.id }
    assert_response :success
    assert_equal sale.id, accounts(:income_sales).reload.default_tax_code_id
  end

  test "a code from a scheme the business does not file is refused" do
    entities(:family_biz).update!(tax_schemes: [])

    patch save_default_tax_code_account_path(accounts(:expenses_general)),
          params: { default_tax_code_id: @code.id }

    assert_response :unprocessable_entity
    assert_nil accounts(:expenses_general).reload.default_tax_code_id
  end

  test "an account of a business this admin does not run cannot be touched" do
    theirs = Account.create!(code: "501600", name: "Not yours", account_type: :expense)

    patch save_default_tax_code_account_path(theirs),
          params: { default_tax_code_id: @code.id }

    assert_nil theirs.reload.default_tax_code_id
  end

  test "the account's remembered code reaches the form as a data attribute" do
    accounts(:expenses_general).update!(default_tax_code: @code)

    get new_withdrawal_account_path(@bank)

    assert_select "select.posting-account option[data-default-tax-code=?]", @code.id.to_s
  end

  # The derived leg is not a row the user owns, so it must not come back as one.
  # Import VAT paid at the border: the whole amount is the VAT, by the code's
  # own shape, so a copy needs nothing typed into the VAT field to come back
  # whole. It used to come back with the field empty, and submitting it as
  # rendered booked the payment as plain expense with no leg at all.
  test "a copy of an import-VAT entry books the whole amount as VAT again" do
    c79 = TaxCode.resolve(scheme: "gb_vat", key: "purchase_import_c79", on: Date.new(2026, 5, 1))
    je = JournalEntry.new(entry_date: Date.new(2026, 5, 1), memo: "customs", posted: true)
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                      amount: 5_000, tax_code_id: c79.id)
    je.derive_tax_legs
    je.postings.build(account: @bank, entry_type: :credit, amount: 5_000, currency: "GBP")
    je.save!

    get copy_withdrawal_account_path(@bank, journal_entry_id: je.id)
    assert_response :success
    assert_select "input.posting-amount[value='50.00']"
    assert_select "input.posting-tax-amount[readonly][value='50.00']"

    assert_difference -> { JournalEntry.count }, 1 do
      post create_withdrawal_account_path(@bank), params: { journal_entry: {
        entry_date: "2026-06-01", memo: "customs again",
        postings_attributes: { "0" => { account_id: accounts(:expenses_general).id,
                                        entry_type: "debit", amount_display: "50.00",
                                        tax_code_id: c79.id, tax_amount_display: "" } } } }
    end
    copy = JournalEntry.order(:id).last
    assert_equal 5_000, copy.postings.find(&:tax_leg?).amount, "all of it is VAT"
    assert_equal 0, copy.postings.find { |p| p.tax_code_id }.amount
  end

  test "a copy does not bring the derived VAT leg back as a posting row" do
    get copy_withdrawal_account_path(@bank, journal_entry_id: @je.id)

    # One coded row in the table, not a second row for the VAT leg itself.
    # (Scoped to tbody: the <template> new rows are cloned from also holds one.)
    assert_select "#bank-postings-table tbody select.posting-tax-code", count: 1
  end
end
