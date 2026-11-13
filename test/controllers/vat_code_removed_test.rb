# frozen_string_literal: true

require "test_helper"

# Removing the only VAT code from an entry, the way a user does it: in the
# form, with the amount as the form sends it. The journal form refused this
# ("must balance") and the bank form booked the bank at gross plus VAT, because
# the VAT was only worked out while some row still had a code.
class VatCodeRemovedTest < ActionDispatch::IntegrationTest
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    entities(:family_biz).update!(tax_schemes: [ "gb_vat" ])
    sign_in_as(admins(:two))

    code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: Date.new(2026, 5, 1))
    @je = JournalEntry.new(entry_date: Date.new(2026, 5, 1), memo: "kit", posted: true)
    @row  = @je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                               amount: 12_000, tax_code_id: code.id)
    @bank = @je.postings.build(account: accounts(:bank_gbp), entry_type: :credit,
                               amount: 12_000, currency: "GBP")
    @je.save!
  end

  def saved = JournalEntry.find(@je.id).postings.map { |p| [ p.account_id, p.amount, p.tax_leg? ] }

  test "the bank form keeps the bank at what left the account" do
    patch update_withdrawal_account_path(accounts(:bank_gbp), journal_entry_id: @je.id),
          params: { journal_entry: { entry_date: "2026-05-01", memo: "kit", postings_attributes: {
            "0" => { id: @row.id, account_id: @row.account_id, entry_type: "debit",
                     amount_display: "120.00", tax_code_id: "" } } } }

    assert_response :redirect
    assert_equal [ [ accounts(:bank_gbp).id, 12_000, false ], [ accounts(:expenses_general).id, 12_000, false ] ].sort,
                 saved.sort
  end

  test "the journal form saves it" do
    patch journal_entry_path(@je), params: { journal_entry: { entry_date: "2026-05-01", memo: "kit",
      postings_attributes: {
        "0" => { id: @row.id, account_id: @row.account_id, entry_type: "debit",
                 amount_display: "120.00", tax_code_id: "" },
        "1" => { id: @bank.id, account_id: @bank.account_id, entry_type: "credit",
                 amount_display: "120.00" } } } }

    assert_response :redirect
    assert_equal [ [ accounts(:bank_gbp).id, 12_000, false ], [ accounts(:expenses_general).id, 12_000, false ] ].sort,
                 saved.sort
  end
end
