require "application_system_test_case"

# A VAT quarter from start to finish, clicked through in a browser: the return
# marked final, a locked entry refused, the payment as a transfer, the clearing
# entry left alone, and both ways of reopening. The confirm() questions and the
# TomSelect transfer selects are browser-side, so no other test sees them.
class VatFinalTest < ApplicationSystemTestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "gb_vat" ])
    @group  = @entity.report_groups.create!(tax_scheme: "gb_vat", name: "GB-VAT")
    @date   = Date.new(2026, 5, 15)
    @sale     = entry(60_000, "sale_standard",     accounts(:income_sales),     :credit)
    @purchase = entry(12_000, "purchase_standard", accounts(:expenses_general), :debit)
    @q2 = @group.reports.create!(name: "Q2 2026", start_date: Date.new(2026, 4, 1),
                                 end_date: Date.new(2026, 6, 30))
    sign_in_system(admins(:two))
  end

  teardown do
    FileUtils.rm_rf(uploads_path("vat_returns"))
  end

  def entry(gross, key, account, side)
    code = TaxCode.resolve(scheme: "gb_vat", key: key, on: @date)
    je = JournalEntry.new(entry_date: @date, memo: key, posted: true)
    je.postings.build(account: account, entry_type: side, amount: gross, tax_code_id: code.id)
    je.derive_tax_legs
    balance = je.postings.sum { |p| p.debit? ? p.amount.to_i : -p.amount.to_i }
    je.postings.build(account: accounts(:bank_gbp), entry_type: balance.positive? ? :credit : :debit,
                      amount: balance.abs, currency: "GBP")
    je.save!
    je
  end

  def sales_account = Account.vat_control_accounts.for_entity_codes([ "10" ]).find_by!(vat_role: "output")

  def credit_balance(account)
    scope = Posting.joins(:journal_entry).where(account_id: account.id, journal_entries: { posted: true })
    scope.credit.sum(:amount) - scope.debit.sum(:amount)
  end

  def mark_final
    visit app_url("/en/reports/#{@q2.id}")
    assert_text "Draft"
    accept_confirm(/submitted this return/) { click_button "Mark as final" }
    assert_text "Final since"
  end

  test "a quarter from draft to final to paid" do
    mark_final

    assert @q2.reload.finalized?
    assert_link "CSV as submitted"
    assert_equal 8_000, credit_balance(sales_account), "VAT on sales now holds what HMRC is owed"

    # A locked entry, opened and saved with a change, comes back refused.
    visit app_url("/en/journal_entries/#{@sale.id}/edit")
    fill_in "journal_entry_memo", with: "changed after filing"
    click_button "Update Journal Entry"
    assert_text "Q2 2026"
    assert_equal "sale_standard", @sale.reload.memo

    # The clearing entry offers no way to change it.
    clearing = @q2.vat_clearing_entry
    visit app_url("/en/journal_entries/#{clearing.id}")
    assert_no_link "Edit"
    assert_no_link "Copy"
    assert_no_button "Unpost"

    # Paying: a transfer from the bank to "VAT payment – HMRC".
    visit app_url("/en/accounts/#{accounts(:bank_gbp).id}/new_transfer")
    assert_selector "#journal_entry_to_account_id.tomselected", visible: :all
    labels = all("#journal_entry_to_account_id option", visible: :all).map(&:text)
    assert labels.any? { |l| l.include?("VAT payment – HMRC") }, labels.inspect
    assert labels.none? { |l| l.include?("VAT on purchases") }, "VAT on purchases is not offered"
    page.execute_script(<<~JS, sales_account.id.to_s)
      document.getElementById('journal_entry_to_account_id').tomselect.setValue(arguments[0]);
    JS
    find("#journal_entry_transfer_amount_display").set("80.00")
    click_button "Save Transfer"
    assert_current_path %r{/accounts/#{accounts(:bank_gbp).id}/ledger}

    assert_equal 0, credit_balance(sales_account), "paid: nothing left owing"
  end

  test "reopening a submitted return takes the question, the warning and a confirmation" do
    mark_final

    click_link "Reopen"
    assert_text "Have you already submitted this return to HMRC?"
    click_link "Yes, it is submitted"
    assert_text "Stop."
    accept_confirm(/submitted return/) { click_button "I understand: reopen anyway" }

    assert_text "open again"
    assert_not @q2.reload.finalized?
    assert_nil @q2.vat_clearing_entry
  end

  test "reopening a return not yet submitted takes one click" do
    mark_final

    click_link "Reopen"
    click_button "No, not submitted yet: reopen"

    assert_text "open again"
    assert_text "Draft"
    assert_not @q2.reload.finalized?
  end

  test "a cancelled confirmation leaves the return a draft" do
    visit app_url("/en/reports/#{@q2.id}")
    dismiss_confirm { click_button "Mark as final" }

    assert_text "Draft"
    assert_not @q2.reload.finalized?
  end

  test "a flat-rate report suggests the last rate and warns when it is left out" do
    @q2.update!(flat_rate_bps: 1_450)

    visit app_url("/en/report_groups/#{@group.id}/reports/new")
    assert_equal "14.5", find("#report_flat_rate_percentage")[:placeholder]
    assert_equal "", find("#report_flat_rate_percentage").value, "suggested, never filled in"

    fill_in "report_name", with: "Q3 2026"
    # Typed into a date input, the digits land in the browser's own field
    # order; the value attribute is the ISO date whatever the locale.
    page.execute_script("document.getElementById('report_start_date').value = '2026-07-01'")
    page.execute_script("document.getElementById('report_end_date').value = '2026-09-30'")
    click_button "Create Report"

    assert_text "Are you sure you don't want to use the flat rate"
  end
end
