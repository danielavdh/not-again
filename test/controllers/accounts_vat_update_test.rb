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

  # The edit paths used to preload the legs twice over — once among the entry's
  # postings, which derivation updates, and once on the net row, which the
  # form read. Nothing is saved on a refused edit, so the form showed the OLD
  # leg added onto the NEW gross: 240.00 typed came back as 260.00, and fixing
  # only the date then booked 260.00 against a 240.00 statement line.
  test "a refused edit re-renders the gross as submitted" do
    patch update_withdrawal_account_path(@bank, journal_entry_id: @je.id),
          params: submitted(amount_display: "240.00", tax_amount_display: "40.00")
                    .deep_merge(journal_entry: { entry_date: "2010-01-01" })

    assert_response :unprocessable_entity, "the code did not exist in 2010"
    assert_select "input.posting-amount[value='240.00']"
    assert_select "input.posting-amount[value='260.00']", count: 0
  end

  # A client that sends the row with no amount at all. What the column holds
  # is the NET of the last derivation, and taking that for the gross shrank
  # net, VAT and bank together, and said "updated".
  test "an update that omits the amount leaves the figures alone" do
    patch update_withdrawal_account_path(@bank, journal_entry_id: @je.id),
          params: { journal_entry: { entry_date: "2026-05-01", memo: "kit",
                      postings_attributes: {
                        "0" => { id: @net.id, tax_code_id: @code.id },
                        "1" => { id: @je.postings.find { |p| p.account_id == @bank.id }.id,
                                 account_id: @bank.id, entry_type: "credit", currency: "GBP" } } } }

    assert_response :redirect
    @je.reload
    assert_equal 10_000, @je.postings.find { |p| p.account_id == @expense.id }.amount
    assert_equal 2_000,  @je.postings.find(&:tax_leg?).amount
    assert_equal 12_000, @je.postings.find { |p| p.account_id == @bank.id }.amount
  end

  # The form's code list is built from what the business files TODAY. An entry
  # from a year it did file would come back with a select that no longer held
  # its code, and saving that dropped the code without a word.
  test "an entry from a year the business filed still offers its code after unsubscribing" do
    entities(:family_biz).update!(tax_schemes: [])

    get edit_withdrawal_account_path(@bank, journal_entry_id: @je.id)

    assert_response :success
    assert_select "select.posting-tax-code option[selected][value='#{@code.id}']"
    assert_select "div.tax-fields.hidden", { count: 0 }, "and the cell is shown"
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
