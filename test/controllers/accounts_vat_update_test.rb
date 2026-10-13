# frozen_string_literal: true

require "test_helper"

# Re-saving a VAT entry from the bank form, which is what a user does when they
# correct a description or a date. The derived leg is not a row in the form, so
# nothing is submitted for it — it has to survive, be re-derived, and must not
# reappear as a second row with no account.
class AccountsVatUpdateTest < ActionDispatch::IntegrationTest
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    entities(:family_biz).update!(tax_schemes: [ "gb_vat" ])
    sign_in_as(admins(:two))
    @bank    = accounts(:bank_gbp)
    @expense = accounts(:expenses_general)
    @code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: Date.new(2026, 5, 1))

    @je = JournalEntry.new(entry_date: Date.new(2026, 5, 1), memo: "kit", posted: true)
    @je.postings.build(account: @expense, entry_type: :debit, amount: 12_000,
                       tax_code_id: @code.id)
    @je.derive_tax_legs
    @je.postings.build(account: @bank, entry_type: :credit, amount: 12_000, currency: "GBP")
    @je.save!

    @net = @je.postings.reload.find { |p| p.account_id == @expense.id }
    @leg = @je.postings.find(&:tax_leg?)
  end

  # Exactly what the form posts: the net row by id, carrying the GROSS and the
  # VAT, and the bank row. Nothing at all for the derived leg.
  def submitted(overrides = {})
    { journal_entry: {
        entry_date: "2026-05-01", memo: "kit, corrected",
        postings_attributes: {
          "0" => { id: @net.id, account_id: @expense.id, entry_type: "debit",
                   amount_display: "120.00", tax_code_id: @code.id,
                   tax_amount_display: "20.00", description: "" }.merge(overrides),
          "1" => { id: @je.postings.find { |p| p.account_id == @bank.id }.id,
                   account_id: @bank.id, entry_type: "credit", currency: "GBP" }
        } } }
  end

  test "re-saving an unchanged VAT entry succeeds and adds no row" do
    patch update_withdrawal_account_path(@bank, journal_entry_id: @je.id), params: submitted

    assert_response :redirect, "errors: #{@je.reload.errors.full_messages.inspect}"
    @je.reload
    assert_equal 3, @je.postings.count, "net, bank and the one derived leg"
    assert_equal 10_000, @je.postings.find { |p| p.account_id == @expense.id }.amount
    assert_equal @leg.id, @je.postings.find(&:tax_leg?).id, "the same leg, not a new one"
  end

  # The path that produced an orphan in the real books: an entry saved with NO
  # code, then a code added and saved. The leg is built fresh against a row that
  # is already persisted, so its link must be written — a leg with no link is
  # invisible to derive_tax_legs for ever after, and shows up in the form as a
  # row whose account cannot even be selected.
  test "adding a code to an already-saved entry links the new leg to its row" do
    plain = JournalEntry.new(entry_date: Date.new(2026, 5, 2), memo: "no vat yet", posted: true)
    plain.postings.build(account: @expense, entry_type: :debit, amount: 12_000)
    plain.postings.build(account: @bank, entry_type: :credit, amount: 12_000, currency: "GBP")
    plain.save!
    net  = plain.postings.find { |p| p.account_id == @expense.id }
    bank = plain.postings.find { |p| p.account_id == @bank.id }

    patch update_withdrawal_account_path(@bank, journal_entry_id: plain.id), params: {
      journal_entry: {
        entry_date: "2026-05-02", memo: "no vat yet",
        postings_attributes: {
          "0" => { id: net.id, account_id: @expense.id, entry_type: "debit",
                   amount_display: "120.00", tax_code_id: @code.id,
                   tax_amount_display: "20.00" },
          "1" => { id: bank.id, account_id: @bank.id, entry_type: "credit", currency: "GBP" }
        } } }

    plain.reload
    leg = plain.postings.detect { |p| p.account&.vat_role.present? }
    assert leg, "a VAT leg should have been derived"
    assert_equal net.id, leg.tax_for_posting_id,
                 "without this the leg is orphaned and shows as an unselectable row"
    assert leg.tax_leg?
  end

  test "changing only the memo leaves the figures alone" do
    patch update_withdrawal_account_path(@bank, journal_entry_id: @je.id), params: submitted

    @je.reload
    bank = @je.postings.find { |p| p.account_id == @bank.id }
    assert_equal 12_000, bank.amount, "the statement has not changed"
    assert_equal 2_000,  @je.postings.find(&:tax_leg?).amount
  end
end
