# frozen_string_literal: true

require "test_helper"

# Marking a VAT return final: the entries of its period stop moving, the two
# VAT accounts are cleared for the period, and the figures as submitted are
# kept. Reopening undoes the first two and keeps the third.
class Reports::VatReturnFinalTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "gb_vat" ])
    @group  = @entity.report_groups.create!(tax_scheme: "gb_vat", name: "GB-VAT")
    @date   = Date.new(2026, 5, 15)
    @q2     = @group.reports.create!(name: "Q2 2026", start_date: Date.new(2026, 4, 1),
                                     end_date: Date.new(2026, 6, 30))
  end

  teardown do
    FileUtils.rm_rf(uploads_path("vat_returns"))
  end

  def code(key) = TaxCode.resolve(scheme: "gb_vat", key: key, on: @date)

  def sales_account     = Account.vat_control_accounts.for_entity_codes([ "10" ]).find_by!(vat_role: "output")
  def purchases_account = Account.vat_control_accounts.for_entity_codes([ "10" ]).find_by!(vat_role: "input")

  # Built the way the bank form builds it: derive, then sum into the bank leg.
  def entry(gross:, key:, account:, side:, date: @date)
    je = JournalEntry.new(entry_date: date, memo: key, posted: true)
    je.postings.build(account: account, entry_type: side, amount: gross, tax_code_id: code(key).id)
    je.derive_tax_legs
    balance = je.postings.reject(&:marked_for_destruction?)
                .sum { |p| p.debit? ? p.amount.to_i : -p.amount.to_i }
    je.postings.build(account: accounts(:bank_gbp),
                      entry_type: balance.positive? ? :credit : :debit,
                      amount: balance.abs, currency: "GBP")
    je.save!
    je
  end

  def uncoded_entry(amount:, date: @date)
    je = JournalEntry.new(entry_date: date, memo: "wages", posted: true)
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit, amount: amount)
    je.postings.build(account: accounts(:bank_gbp), entry_type: :credit, amount: amount, currency: "GBP")
    je.save!
    je
  end

  def finalize!(report = @q2)
    data = report.vat_return_data
    Reports::VatReturnFinal.new(report).finalize!(data: data, csv: Reports::VatReturnCsv.new(data: data).generate)
  end

  # Credit balance for the liability, debit balance for the asset, over the
  # period: what each account says the business owes or is owed.
  def movement(account, from: @q2.start_date, to: @q2.end_date)
    scope = Posting.joins(:journal_entry).where(account_id: account.id,
                                                journal_entries: { posted: true, entry_date: from..to })
    scope.credit.sum(:amount) - scope.debit.sum(:amount)
  end

  def sale_and_purchase
    entry(gross: 60_000, key: "sale_standard",     account: accounts(:income_sales),     side: :credit)
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
  end

  test "final clears VAT on purchases into VAT on sales, which then holds what is owed" do
    sale_and_purchase

    clearing = finalize!

    assert @q2.reload.finalized?
    assert_equal @q2.end_date, clearing.entry_date
    assert_equal 0, movement(purchases_account), "the period's VAT on purchases has moved over"
    assert_equal 8_000, movement(sales_account), "100.00 charged less 20.00 paid: what HMRC is owed"
    assert_equal 8_000, @q2.vat_return_data[:net_payable], "the account agrees with the return"
  end

  test "the clearing entry does not change the return it clears" do
    sale_and_purchase
    before = @q2.vat_return_data

    finalize!
    after = @q2.vat_return_data

    assert_equal Reports::VatReturnFinal.fingerprint(before), Reports::VatReturnFinal.fingerprint(after)
    assert_equal 0, after[:unassigned]
  end

  # A reverse charge posts no VAT at all, so nothing of it is moved — yet the
  # return's due and reclaimed both include it. Moving the return's figures
  # instead of the posted ones would leave VAT on purchases negative.
  test "a reverse charge moves nothing and leaves both accounts right" do
    sale_and_purchase
    entry(gross: 10_000, key: "purchase_reverse_charge_services",
          account: accounts(:expenses_general), side: :debit)

    finalize!

    assert_equal 0, movement(purchases_account)
    assert_equal 8_000, movement(sales_account)
  end

  test "a period without VAT books no clearing entry and is still final" do
    assert_nil finalize!
    assert @q2.reload.finalized?
  end

  test "the CSV as it was is kept, with the figures' fingerprint in its name" do
    sale_and_purchase
    data = @q2.vat_return_data

    finalize!

    file = VatReturnStorage.latest(@q2.id)
    assert_equal Reports::VatReturnFinal.fingerprint(data), file.fingerprint
    assert_match "80.00", VatReturnStorage.read(file.key), "net payable in the stored file"
  end

  test "a figure changed behind the lock changes the fingerprint" do
    sale_and_purchase
    finalize!

    # What the catalogue loader may do: rewrite a posting without validation.
    leg = Posting.where.not(tax_for_posting_id: nil).where(account_id: sales_account.id).first
    leg.update_column(:amount, leg.amount + 100)

    assert_not_equal VatReturnStorage.latest(@q2.id).fingerprint,
                     Reports::VatReturnFinal.fingerprint(@q2.vat_return_data)
  end

  # --- the lock ------------------------------------------------------------

  test "a coded entry in a final period cannot be edited" do
    sale = entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    finalize!

    sale.memo = "changed"
    assert_not sale.save
    assert_match "Q2 2026", sale.errors.full_messages.to_sentence
  end

  test "nor deleted, posted or unposted" do
    sale = entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    finalize!

    assert_not sale.destroy
    assert_not sale.unpost!
    assert sale.reload.posted?
    assert_not sale.post!
  end

  test "a new coded entry cannot be dated inside a final period" do
    finalize!

    assert_raises(ActiveRecord::RecordInvalid) do
      entry(gross: 1_200, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    end
  end

  test "a zero-rated entry is part of the return and locked too" do
    sale = entry(gross: 5_000, key: "sale_zero", account: accounts(:income_sales), side: :credit)
    finalize!

    sale.memo = "changed"
    assert_not sale.save
  end

  test "a coded entry cannot be moved out of a final period" do
    sale = entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    finalize!

    sale.entry_date = Date.new(2026, 7, 2)
    assert_not sale.save, "moving it out would change the submitted figures"
  end

  test "a coded entry cannot be moved into a final period" do
    finalize!
    later = entry(gross: 1_200, key: "purchase_standard", account: accounts(:expenses_general),
                  side: :debit, date: Date.new(2026, 7, 2))

    later.entry_date = @date
    assert_not later.save
  end

  test "an uncoded entry in a final period may still be edited, but not given a code" do
    wages = uncoded_entry(amount: 3_000)
    finalize!

    wages.memo = "salaries"
    assert wages.save, "not part of the return: nothing to lock"

    wages.postings.find { |p| p.account_id == accounts(:expenses_general).id }.tax_code_id = code("purchase_standard").id
    assert_not wages.save, "a code would put it into the submitted return"
  end

  test "saving a locked entry without a change is not refused" do
    sale = entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    finalize!

    assert sale.reload.save
  end

  test "another business's entries are not locked by this return" do
    sale = entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    Report.where(id: @q2.id).update_all(finalized_at: Time.current)
    Report.where(id: @q2.id).joins(:report_group).first.report_group.update_column(:entity_id, entities(:standalone).id)

    sale.memo = "changed"
    assert sale.save
  end

  # --- the clearing entry is the app's ----------------------------------------

  test "the clearing entry cannot be edited, unposted or deleted by hand" do
    sale_and_purchase
    clearing = finalize!

    clearing.memo = "mine now"
    assert_not clearing.save
    assert_not clearing.reload.unpost!
    assert_not clearing.destroy
  end

  # --- reopen ------------------------------------------------------------------

  test "reopening removes the clearing entry and the lock, and keeps the file" do
    sale = entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    clearing = finalize!

    removed = Reports::VatReturnFinal.new(@q2.reload).reopen!

    assert_equal clearing.id, removed.id
    assert_not JournalEntry.exists?(clearing.id)
    assert_not @q2.reload.finalized?
    sale.memo = "corrected"
    assert sale.save, "the period is open again"
    assert_equal 1, VatReturnStorage.list(@q2.id).size, "the submitted version is still there"
  end

  test "finalising again after a reopen adds a second file" do
    sale_and_purchase
    finalize!
    Reports::VatReturnFinal.new(@q2.reload).reopen!
    finalize!(@q2.reload)

    assert_equal 2, VatReturnStorage.list(@q2.id).size
  end

  # --- the report itself ------------------------------------------------------

  test "a final report cannot be deleted or have its period or rate changed, but can be renamed" do
    finalize!

    assert_not @q2.destroy
    assert_not @q2.update(end_date: Date.new(2026, 7, 31))
    @q2.reload
    assert @q2.update(name: "Q2 2026 (filed)")
  end

  # --- flat rate -------------------------------------------------------------

  test "a flat-rate return books the difference to the flat-rate income account" do
    @q2.update!(flat_rate_bps: 1_000)
    sale_and_purchase
    data = @q2.vat_return_data

    finalize!

    flat = Account.vat_accounts.for_entity_codes([ "10" ]).find_by!(vat_role: "flat_rate")
    assert flat.income?
    payable = data[:vat_due] - data[:vat_reclaimed]
    assert_equal 6_000, payable, "10 % of the 600.00 gross the sale took in"
    assert_equal payable, movement(sales_account), "VAT on sales holds what the flat rate asks for"
    assert_equal 0, movement(purchases_account)
    # 100.00 charged - 20.00 paid - 60.00 owed
    assert_equal 2_000, movement(flat), "the difference is income"
  end

  test "a flat-rate difference that is a loss books as negative income" do
    @q2.update!(flat_rate_bps: 1_650)
    entry(gross: 12_000, key: "sale_standard",     account: accounts(:income_sales),     side: :credit)
    entry(gross: 6_000,  key: "purchase_standard", account: accounts(:expenses_general), side: :debit)

    finalize!

    flat = Account.vat_accounts.for_entity_codes([ "10" ]).find_by!(vat_role: "flat_rate")
    # 20.00 charged - 10.00 paid - 19.80 owed (16.5 % of 120.00)
    assert_equal(-980, movement(flat))
    assert_equal 1_980, movement(sales_account)
  end

  test "the flat-rate account is not a control account" do
    Account.resolve_vat_account(entity_code: "10", scheme: "gb_vat", direction: "flat_rate")

    assert_equal %w[input output].sort,
                 Account.vat_control_accounts.for_entity_codes([ "10" ]).where(tax_scheme: "gb_vat")
                        .pluck(:vat_role).sort
  end
end
