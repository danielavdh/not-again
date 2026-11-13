# frozen_string_literal: true

require "test_helper"

# The VAT return page: marking final, the way back, and what the forms around
# it offer.
class ReportsVatFinalTest < ActionDispatch::IntegrationTest
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "gb_vat" ])
    @group  = @entity.report_groups.create!(tax_scheme: "gb_vat", name: "GB-VAT")
    sign_in_as(admins(:two))

    @date = Date.new(2026, 5, 15)
    entry(12_000, "purchase_standard", accounts(:expenses_general), :debit)
    entry(60_000, "sale_standard",     accounts(:income_sales),     :credit)

    @q2 = @group.reports.create!(name: "Q2 2026", start_date: Date.new(2026, 4, 1),
                                 end_date: Date.new(2026, 6, 30))
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

  test "a draft return offers the button, and pressing it makes the return final" do
    get report_path(@q2)
    assert_select "form[action='#{finalize_report_path(@q2)}']"

    post finalize_report_path(@q2)

    assert_redirected_to report_path(@q2)
    assert @q2.reload.finalized?
    assert @q2.vat_clearing_entry.present?
  end

  test "a final return offers its kept CSV, and the books unchanged say nothing" do
    post finalize_report_path(@q2)

    get report_path(@q2)
    file = VatReturnStorage.latest(@q2.id)
    assert_select "a[href='#{download_final_vat_return_report_path(@q2, key: file.filename)}']"
    assert_select "p.warning", count: 0

    get download_final_vat_return_report_path(@q2, key: file.filename)
    assert_response :success
    assert_match "80.00", response.body
  end

  test "a figure changed behind the lock is reported on the page" do
    post finalize_report_path(@q2)
    leg = Posting.where.not(tax_for_posting_id: nil).where(account_id: sales_account.id).first
    leg.update_column(:amount, leg.amount + 100)

    get report_path(@q2)
    assert_select "p.warning"
  end

  test "a forged filename is not served" do
    post finalize_report_path(@q2)

    get download_final_vat_return_report_path(@q2, key: "../../tax_exports/1/x.csv")
    assert_redirected_to report_path(@q2)
  end

  # --- reopening ---------------------------------------------------------------

  test "reopen asks first, and a not-submitted answer reopens" do
    post finalize_report_path(@q2)

    get reopen_report_path(@q2)
    assert_response :success
    assert_match "HMRC", response.body

    patch unfinalize_report_path(@q2), params: { submitted: "no" }
    assert_redirected_to report_path(@q2)
    assert_not @q2.reload.finalized?
    assert_nil @q2.vat_clearing_entry
  end

  test "a submitted answer shows the warning, and only its confirmation reopens" do
    post finalize_report_path(@q2)

    get reopen_report_path(@q2, submitted: "yes")
    assert_select "form[action='#{unfinalize_report_path(@q2)}'] input[name='confirmed'][value='1']"

    patch unfinalize_report_path(@q2), params: { submitted: "yes" }
    assert_redirected_to reopen_report_path(@q2)
    assert @q2.reload.finalized?, "an answer without the confirmation reopens nothing"

    patch unfinalize_report_path(@q2), params: { submitted: "yes", confirmed: "1" }
    assert_not @q2.reload.finalized?
  end

  test "an unanswered reopen reopens nothing" do
    post finalize_report_path(@q2)

    patch unfinalize_report_path(@q2)
    assert @q2.reload.finalized?
  end

  test "a read-only admin can neither finalise nor reopen" do
    sign_in_as(admins(:shared_reader))
    post finalize_report_path(@q2)
    assert_not @q2.reload.finalized?

    Reports::VatReturnFinal.new(@q2).finalize!(data: @q2.vat_return_data, csv: "x")
    patch unfinalize_report_path(@q2), params: { submitted: "no" }
    assert @q2.reload.finalized?
  end

  test "a final report cannot be deleted from the page" do
    post finalize_report_path(@q2)

    delete report_path(@q2)
    assert Report.exists?(@q2.id)
  end

  # --- entries -------------------------------------------------------------------

  test "the clearing entry is never copied as one" do
    post finalize_report_path(@q2)
    clearing = @q2.reload.vat_clearing_entry

    get duplicate_journal_entry_path(clearing)
    assert_response :success
    assert_select "input[name='journal_entry[vat_report_id]']", count: 0
  end

  test "unposting a locked entry says why" do
    post finalize_report_path(@q2)
    sale = JournalEntry.find_by!(memo: "sale_standard")

    patch unpost_journal_entry_path(sale)
    assert sale.reload.posted?
    follow_redirect!
    assert_match "Q2 2026", response.body
  end

  # --- the transfer form ------------------------------------------------------

  test "the transfer form offers VAT on sales as payment and refund, and not VAT on purchases" do
    purchases = Account.vat_control_accounts.for_entity_codes([ "10" ]).find_by!(vat_role: "input")

    get new_transfer_account_path(accounts(:bank_gbp))

    assert_select "#journal_entry_to_account_id option[value='#{sales_account.id}']",
                  text: /#{sales_account.code} - .*HMRC/
    assert_select "#journal_entry_from_account_id option[value='#{sales_account.id}']",
                  text: /#{sales_account.code} - .*HMRC/
    assert_select "option[value='#{purchases.id}']", count: 0
  end

  # --- a closed year --------------------------------------------------------------

  def year_profit
    close = JournalEntry.find_by!(closing_entry: true, period_end: Date.new(2026, 12, 31))
    scope = close.postings.where(account_id: Account.retained_earnings.select(:id))
    scope.credit.sum(:amount) - scope.debit.sum(:amount)
  end

  # The flat-rate difference is income, so a return marked final inside a year
  # already closed changes that year's profit, and reopening it changes it back.
  test "a flat-rate return marked final in a closed year moves the year's closing entry" do
    @q2.update!(flat_rate_bps: 1_000)
    YearEndService.new(entity: @entity, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 12, 31)).call
    before = year_profit

    post finalize_report_path(@q2)
    # 100.00 charged - 20.00 paid - 60.00 owed at 10 % of 600.00
    assert_equal before + 2_000, year_profit

    patch unfinalize_report_path(@q2), params: { submitted: "no" }
    assert_equal before, year_profit
  end

  # --- flat rate ---------------------------------------------------------------

  test "a report with a flat rate creates the flat-rate income account once" do
    post report_group_reports_path(@group),
         params: { report: { name: "Q3", start_date: "2026-07-01", end_date: "2026-09-30",
                             flat_rate_percentage: "14.5" } }

    flat = Account.vat_accounts.for_entity_codes([ "10" ]).where(vat_role: "flat_rate")
    assert_equal 1, flat.count
    assert flat.first.income?

    post report_group_reports_path(@group),
         params: { report: { name: "Q4", start_date: "2026-10-01", end_date: "2026-12-31",
                             flat_rate_percentage: "14.5" } }
    assert_equal 1, flat.count
  end

  test "leaving the rate out after a flat-rate report says so" do
    @q2.update!(flat_rate_bps: 1_450)

    post report_group_reports_path(@group),
         params: { report: { name: "Q3", start_date: "2026-07-01", end_date: "2026-09-30" } }

    assert_match "14.5", flash[:notice]
  end

  test "the new report's placeholder is the last rate used" do
    @q2.update!(flat_rate_bps: 1_450)

    get new_report_group_report_path(@group)
    assert_select "input[name='report[flat_rate_percentage]'][placeholder='14.5']"
    assert_select "input[name='report[flat_rate_percentage]'][value]", count: 0
  end
end
