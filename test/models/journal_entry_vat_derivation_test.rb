# frozen_string_literal: true

require "test_helper"

# The VAT legs are the entry's own business: whoever saves it — a form, a
# script, an importer — gets the split, and taking the code away takes the VAT
# back out of the control account and into the row.
class JournalEntryVatDerivationTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    entities(:family_biz).update!(tax_schemes: [ "gb_vat" ])
    @date = Date.new(2026, 5, 1)
    @code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: @date)
  end

  def purchase
    je = JournalEntry.new(entry_date: @date, memo: "kit", posted: true)
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                      amount: 12_000, tax_code_id: @code.id)
    je.postings.build(account: accounts(:bank_gbp), entry_type: :credit, amount: 12_000, currency: "GBP")
    je
  end

  def row(je) = je.postings.reload.find { |p| p.account_id == accounts(:expenses_general).id }
  def legs(je) = je.postings.reload.select(&:tax_leg?)

  test "a coded entry saved without anyone asking for the split still gets it" do
    je = purchase
    je.save!

    assert_equal 10_000, row(je).amount, "the net, not the gross"
    assert_equal [ 2_000 ], legs(je).map(&:amount)
  end

  test "asking for the split first and then saving does not split twice" do
    je = purchase
    je.derive_tax_legs
    je.save!

    assert_equal 10_000, row(je).amount
    assert_equal 1, legs(je).size
  end

  test "taking the code away puts the VAT back into the row and removes the leg" do
    je = purchase
    je.save!

    je = JournalEntry.find(je.id)
    row(je).tax_code_id = nil
    je.save!

    assert_equal 12_000, row(je).amount, "the gross again"
    assert_empty legs(je)
    assert_equal 12_000, je.postings.find { |p| p.account_id == accounts(:bank_gbp).id }.amount
  end

  test "an entry with no VAT anywhere is not touched" do
    je = JournalEntry.new(entry_date: @date, memo: "wages", posted: true)
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit, amount: 5_000)
    je.postings.build(account: accounts(:bank_gbp), entry_type: :credit, amount: 5_000, currency: "GBP")
    je.save!

    assert_equal 5_000, row(je).amount
    assert_empty legs(je)
  end
end
