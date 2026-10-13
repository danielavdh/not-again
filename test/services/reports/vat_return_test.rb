# frozen_string_literal: true

require "test_helper"

# The return as an accountant would check it: the boxes against the entries
# that produced them, and the net payable against what actually left or is owed.
class Reports::VatReturnTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "gb_vat" ])
    @date = Date.new(2026, 5, 15)
  end

  def code(key) = TaxCode.resolve(scheme: "gb_vat", key: key, on: @date)

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

  def result(from: Date.new(2026, 4, 1), to: Date.new(2026, 6, 30))
    Reports::VatReturn.new(entity: @entity, scheme: "gb_vat", from: from, to: to).call
  end

  def box(res, key)
    res[:boxes].find { |b| b.key == key }&.amount
  end

  test "a sale and two purchases land in the right boxes with the right figures" do
    entry(gross: 60_000, key: "sale_standard",     account: accounts(:income_sales),     side: :credit)
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    entry(gross: 10_500, key: "purchase_reduced",  account: accounts(:expenses_fees),    side: :debit)

    res = result

    assert_equal 50_000, box(res, "total_sales_ex_vat"),     "box 6 is the sale's net"
    assert_equal 10_000, box(res, "vat_due_sales"),          "box 1 is the VAT charged"
    # 120.00 at 20% -> net 100.00; 105.00 at 5% -> net 100.00
    assert_equal 20_000, box(res, "total_purchases_ex_vat"), "box 7 is both purchases' net"
    assert_equal 2_500,  box(res, "vat_reclaimed"),          "box 4 is 20.00 + 5.00"

    assert_equal 10_000, res[:vat_due]
    assert_equal 2_500,  res[:vat_reclaimed]
    assert_equal 7_500,  res[:net_payable], "owed to HMRC"
    assert_equal 0,      res[:unassigned],  "every penny in the control accounts came from a code"
  end

  # The box 1 / box 4 pair is the whole point of a reverse charge: it changes no
  # money and both figures must still be reported.
  test "reverse charge reports in both boxes and leaves the net payable alone" do
    entry(gross: 10_000, key: "purchase_reverse_charge",
          account: accounts(:expenses_general), side: :debit)

    res = result

    assert_equal 2_000, box(res, "vat_due_sales"),           "owed as if we had charged ourselves"
    assert_equal 2_000, box(res, "vat_reclaimed"),           "and reclaimed in the same breath"
    assert_equal 10_000, box(res, "total_purchases_ex_vat")
    assert_equal 0, res[:net_payable], "nothing is actually owed"
  end

  # HMRC's box 6 includes the dispatches already shown in box 8, and box 7 the
  # acquisitions shown in box 9. Reporting an NI acquisition in box 9 ALONE
  # understated box 7 — the catalogue now says which boxes total which, so the
  # figure is counted in both.
  test "a Northern Ireland acquisition is in box 9 and in the box 7 total" do
    entry(gross: 10_000, key: "purchase_acquisition_ni_eu",
          account: accounts(:expenses_general), side: :debit)

    res = result
    assert_equal 10_000, box(res, "total_acquisitions_ni"), "box 9, its own line"
    assert_equal 10_000, box(res, "total_purchases_ex_vat"), "and box 7, which totals it"
  end

  test "a dispatch from Northern Ireland is in box 8 and in the box 6 total" do
    entry(gross: 20_000, key: "sale_dispatch_ni_eu",
          account: accounts(:income_sales), side: :credit)

    res = result
    assert_equal 20_000, box(res, "total_dispatches_ni")
    assert_equal 20_000, box(res, "total_sales_ex_vat")
  end

  # Box 3 is the form's own total of boxes 1 and 2, so it needs no code of its
  # own — and a reverse charge is what puts anything in box 2.
  test "box 3 totals the VAT due in boxes 1 and 2" do
    entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    entry(gross: 10_000, key: "purchase_acquisition_ni_eu",
          account: accounts(:expenses_general), side: :debit)

    res = result
    assert_equal 10_000, box(res, "vat_due_sales"),        "box 1, from the sale"
    assert_equal 2_000,  box(res, "vat_due_acquisitions"), "box 2, the acquisition's other half"
    assert_equal 12_000, box(res, "total_vat_due"),        "box 3 is 1 + 2"
  end

  # The two cases that collapsed into one code reach the same boxes, which is
  # why they could collapse.
  test "the general reverse charge fills boxes 1 and 4, not the NI boxes" do
    entry(gross: 10_000, key: "purchase_reverse_charge",
          account: accounts(:expenses_general), side: :debit)

    res = result
    assert_equal 2_000,  box(res, "vat_due_sales")
    assert_equal 2_000,  box(res, "vat_reclaimed")
    assert_equal 10_000, box(res, "total_purchases_ex_vat")
    assert_nil box(res, "total_acquisitions_ni"), "an EU acquisition is a different code"
  end

  test "an entry outside the period is not in the return" do
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    entry(gross: 60_000, key: "purchase_standard", account: accounts(:expenses_general),
          side: :debit, date: Date.new(2026, 8, 1))

    assert_equal 10_000, box(result, "total_purchases_ex_vat")
  end

  test "a refund reduces the box it was charged in" do
    entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    entry(gross: 12_000, key: "sale_standard", account: accounts(:income_sales), side: :debit)

    res = result
    assert_equal 40_000, box(res, "total_sales_ex_vat")
    assert_equal 8_000,  box(res, "vat_due_sales")
  end

  # The check that makes a hand-typed VAT posting audible instead of just
  # missing from the return.
  test "VAT put in the control account by hand is reported as unassigned" do
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    control = Account.vat_accounts.for_entity_codes([ "10" ]).find_by(vat_role: :input)

    hand = JournalEntry.new(entry_date: @date, memo: "typed by hand", posted: true)
    hand.postings.build(account: control, entry_type: :debit, amount: 500, currency: "GBP")
    hand.postings.build(account: accounts(:bank_gbp), entry_type: :credit, amount: 500, currency: "GBP")
    hand.save!

    res = result
    assert_equal 2_000, box(res, "vat_reclaimed"), "the box only holds what a code produced"
    assert_equal(-500, res[:unassigned], "and the difference is named")
  end

  test "a quiet quarter returns zeroes, not an error" do
    res = result
    assert_empty res[:lines]
    assert_empty res[:boxes]
    assert_equal 0, res[:net_payable]
  end

  test "another business's entries are not in this one's return" do
    entities(:daughter).update!(tax_schemes: [ "gb_vat" ])
    je = JournalEntry.new(entry_date: @date, memo: "daughter", posted: true)
    je.postings.build(account: accounts(:daughter_expenses), entry_type: :debit,
                      amount: 12_000, tax_code_id: code("purchase_standard").id)
    je.derive_tax_legs
    je.postings.build(account: accounts(:daughter_bank), entry_type: :credit,
                      amount: 12_000, currency: "GBP")
    je.save!

    assert_empty result[:lines], "entity 10's return holds none of entity 04's VAT"
    other = Reports::VatReturn.new(entity: entities(:daughter), scheme: "gb_vat",
                                   from: Date.new(2026, 4, 1), to: Date.new(2026, 6, 30)).call
    assert_equal 10_000, other[:boxes].find { |b| b.key == "total_purchases_ex_vat" }.amount
  end

  test "an unposted entry is not in the return" do
    je = entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    je.update!(posted: false)

    assert_empty result[:lines]
  end
end
