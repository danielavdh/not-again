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
    entry(gross: 10_000, key: "purchase_reverse_charge_services",
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
    entry(gross: 10_000, key: "purchase_reverse_charge_services",
          account: accounts(:expenses_general), side: :debit)

    res = result
    assert_equal 2_000,  box(res, "vat_due_sales")
    assert_equal 2_000,  box(res, "vat_reclaimed")
    assert_equal 10_000, box(res, "total_purchases_ex_vat")
    assert_equal 0, box(res, "total_acquisitions_ni"), "an EU acquisition is a different code"
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

  # The name was always right and the assertion was not: it demanded an EMPTY
  # return, which is not a thing you can file. A VAT return has nine boxes
  # whatever happened in the quarter, and a nil return is nine zeros.
  test "a quiet quarter returns zeroes, not an error" do
    res = result

    assert_empty res[:lines], "nothing was coded"
    assert_equal 9, res[:boxes].size, "a return still has all its boxes"
    assert_equal %w[1 2 3 4 5 6 7 8 9], res[:boxes].map(&:reference),
                 "in the authority's own order"
    assert res[:boxes].all? { |b| b.amount.zero? }
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

  # --- per account, which is the half an accountant reads ---
  #
  # The by-code table reconciles the boxes. It cannot answer "which expenses
  # bore VAT", and that is the question behind a wrong rate, or input tax that
  # belongs to exempt income.

  def account_line(res, code)
    res[:account_lines].find { |l| l.account_code == code }
  end

  test "each account appears with its own net and its own VAT" do
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    entry(gross: 60_000, key: "sale_standard",     account: accounts(:income_sales),     side: :credit)
    res = result

    expense = account_line(res, accounts(:expenses_general).code)
    assert_equal 10_000, expense.net, "the expense shows net, not gross"
    assert_equal 2_000,  expense.tax

    sale = account_line(res, accounts(:income_sales).code)
    assert_equal 50_000, sale.net, "a sale is positive here, not a credit balance"
    assert_equal 10_000, sale.tax
  end

  # The reason this is per account AND code rather than per account: one expense
  # account carries several rates, and they belong in different boxes.
  test "one account at two rates is two rows, not one blended figure" do
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    entry(gross: 10_500, key: "purchase_reduced",  account: accounts(:expenses_general), side: :debit)

    rows = result[:account_lines].select { |l| l.account_code == accounts(:expenses_general).code }

    assert_equal 2, rows.size
    assert_equal [ 500, 2_000 ], rows.map { |r| r.code.rate_bps }.sort
    assert_equal 2_500, rows.sum(&:tax), "20% of 100 plus 5% of 100"
  end

  # An account nobody coded has no input tax to report or restrict, so it is not
  # on this table — the ledger is where the whole bill lives.
  test "an account with no VAT code is absent" do
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)

    assert_nil account_line(result, accounts(:bank_gbp).code),
               "the bank leg carries no code and belongs nowhere on a VAT breakdown"
  end

  # A reverse charge puts two equal, opposite legs under one code. Summing them
  # blindly gives zero, which would report an account as having borne no VAT.
  test "a reverse charge reports its own side, not the two legs cancelling" do
    entry(gross: 10_000, key: "purchase_reverse_charge_services", account: accounts(:expenses_general), side: :debit)

    line = account_line(result, accounts(:expenses_general).code)
    assert_equal 10_000, line.net
    assert_equal 2_000,  line.tax, "the input side, not nil and not zero"
  end

  test "the account breakdown is scoped to the period like everything else" do
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general),
          side: :debit, date: Date.new(2026, 1, 15))

    assert_empty result[:account_lines], "a January entry is not in the April-June return"
  end

  # --- the box 6 corrections of 2026-10-15 ---
  #
  # These two codes existed as ONE, set the construction way, on the written
  # claim that "the return cannot tell them apart". It can, and the difference
  # is box 6 — so every overseas service bought left box 6 short.

  # Notice 700/12, customer side: "box 1, box 4, box 6 (value of the deemed
  # supply) and box 7".
  test "a reverse charge on services from abroad reaches box 6 as well as box 7" do
    entry(gross: 10_000, key: "purchase_reverse_charge_services",
          account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 10_000, box(res, "total_purchases_ex_vat"), "box 7"
    assert_equal 10_000, box(res, "total_sales_ex_vat"),
                 "box 6 — the deemed supply, which is the whole point of the split"
    assert_equal 2_000, box(res, "vat_due_sales"),  "box 1"
    assert_equal 2_000, box(res, "vat_reclaimed"),  "box 4"
    assert_equal 0, res[:net_payable], "owed and reclaimed cancel"
  end

  # Notice 735, customer side: "the VAT exclusive value of the purchases must
  # not be entered in box 6" — the exact opposite, which is why one code could
  # never serve both.
  test "a construction reverse charge stays out of box 6" do
    entry(gross: 10_000, key: "purchase_reverse_charge_construction",
          account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 10_000, box(res, "total_purchases_ex_vat"), "box 7"
    assert_equal 0, box(res, "total_sales_ex_vat"), "box 6 must not carry it"
  end

  # The category that lets one code feed two boxes is not itself a box, and a
  # reader of the return must never see it among boxes 1 to 9.
  test "the feeder category is not shown as a box" do
    entry(gross: 10_000, key: "purchase_reverse_charge_services",
          account: accounts(:expenses_general), side: :debit)

    refute_includes result[:boxes].map(&:key), "reverse_charge_services_net"
    assert result[:boxes].all? { |b| b.reference.present? },
           "every line on a VAT return has a box number"
  end

  # Exempt and zero-rated both land in box 6, which is why the missing exempt
  # code went unnoticed. They differ everywhere else — the threshold, and
  # whether input tax is recoverable.
  test "exempt sales reach box 6 and charge no VAT" do
    entry(gross: 50_000, key: "sale_exempt", account: accounts(:income_sales), side: :credit)
    res = result

    assert_equal 50_000, box(res, "total_sales_ex_vat"), "box 6"
    assert_equal 0, box(res, "vat_due_sales"), "nothing is due on an exempt supply"
  end

  # Two codes that read almost the same to a user and are not the same to HMRC.
  test "services supplied abroad reach box 6, but genuinely outside-scope income reaches no box" do
    entry(gross: 30_000, key: "sale_services_outside_uk",
          account: accounts(:income_sales), side: :credit)
    assert_equal 30_000, box(result, "total_sales_ex_vat"),
                 "place-of-supply services: 700/12 lists them among box 6"

    JournalEntry.destroy_all
    entry(gross: 30_000, key: "sale_outside_scope",
          account: accounts(:income_sales), side: :credit)
    assert_equal 0, box(result, "total_sales_ex_vat"),
               "a grant or a dividend reaches no box — box 6 stays at zero"
  end

  # The DRC runs at 5% as well as 20% — reduced-rate conversions, renovations of
  # long-empty dwellings, energy-saving work. Only the customer side needs the
  # second code: a supplier posts no VAT at either rate.
  test "the reduced-rate construction reverse charge behaves like the standard one, at 5%" do
    entry(gross: 10_000, key: "purchase_reverse_charge_construction_reduced",
          account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 10_000, box(res, "total_purchases_ex_vat"), "box 7"
    assert_equal 0, box(res, "total_sales_ex_vat"), "box 6 is excluded for construction, at any rate"
    assert_equal 500, box(res, "vat_due_sales"), "box 1 — 5% of 10,000"
    assert_equal 500, box(res, "vat_reclaimed"), "box 4"
    assert_equal 0, res[:net_payable]
  end

  # --- the flat rate scheme ---
  #
  # Notice 733 / 700/12: box 1 is the flat percentage of VAT-INCLUSIVE turnover,
  # box 6 is that same VAT-inclusive turnover, and input tax inside the scheme
  # is not reclaimed. Supplies outside the scheme keep normal treatment.

  def flat(bps, from: Date.new(2026, 4, 1), to: Date.new(2026, 6, 30))
    Reports::VatReturn.new(entity: @entity, scheme: "gb_vat",
                           from: from, to: to, flat_rate_bps: bps).call
  end

  test "box 1 is the flat percentage of VAT-inclusive turnover, not the VAT charged" do
    entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    res = flat(1450)

    assert_equal 60_000, box(res, "total_sales_ex_vat"),
                 "box 6 is the gross under a flat rate, not the net"
    assert_equal 8_700, box(res, "vat_due_sales"), "14.5% of 60,000"
    assert_equal 8_700, res[:vat_due], "the summary agrees with the boxes"
  end

  # 700/12: box 7 is blank under the scheme "unless you've bought a capital good
  # costing more than £2,000 ... include in box 7 any amount you've entered in
  # box 9 and reverse charge transactions". An ordinary purchase reaches
  # neither box 4 nor box 7.
  test "an ordinary purchase reaches no box at all under a flat rate" do
    entry(gross: 60_000, key: "sale_standard",     account: accounts(:income_sales),     side: :credit)
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    res = flat(1450)

    assert_equal 0, box(res, "vat_reclaimed"),          "box 4"
    assert_equal 0, box(res, "total_purchases_ex_vat"), "box 7 is 0.00, not the net of ordinary expenses"
    assert_equal 0, res[:vat_reclaimed]
  end

  # The control accounts hold VAT the boxes deliberately do not account for —
  # that is the scheme working, not an entry someone forgot to code. Saying
  # "find the entry and give it a code" was alarming and wrong.
  test "a flat-rate return reports no unassigned VAT" do
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)

    assert_equal 0, flat(1450)[:unassigned]
  end

  # The carve-out that made this more than two boxes: reverse-charge supplies are
  # "dealt with outside of the Flat Rate Scheme ... but recorded in boxes 1 and 4
  # as you would under normal accounting".
  test "a reverse charge is accounted normally and kept out of flat-rate turnover" do
    entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    entry(gross: 10_000, key: "purchase_reverse_charge_services",
          account: accounts(:expenses_general), side: :debit)
    res = flat(1450)

    assert_equal 2_000, box(res, "vat_reclaimed"),
                 "box 4 is the reverse charge only — the ordinary purchase gave nothing"
    assert_equal 8_700 + 2_000, box(res, "vat_due_sales"),
                 "box 1 is the flat rate PLUS the reverse charge's own output half"
    assert_equal 60_000 + 10_000, box(res, "total_sales_ex_vat"),
                 "box 6: flat-rate turnover gross, plus the outside supply at net"
  end

  test "the comparison shows the same period on the ordinary basis" do
    entry(gross: 60_000, key: "sale_standard",     account: accounts(:income_sales),     side: :credit)
    entry(gross: 12_000, key: "purchase_standard", account: accounts(:expenses_general), side: :debit)
    res = flat(1450)

    filed = res[:boxes].find { |b| b.key == "vat_due_sales" }.amount
    full  = res[:comparison_boxes].find { |b| b.key == "vat_due_sales" }.amount

    assert_equal 8_700,  filed, "what gets filed"
    assert_equal 10_000, full,  "what the ordinary basis would have charged"
    assert_equal 50_000, res[:comparison_boxes].find { |b| b.key == "total_sales_ex_vat" }.amount,
                 "and the comparison keeps box 6 net, as the ordinary basis does"
  end

  test "an ordinary return offers no comparison and no caveats" do
    entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)
    res = result

    assert_nil res[:flat_rate_bps]
    assert_empty res[:comparison_boxes]
  end

  # The app chooses no VAT rate for anyone and tells nobody what belongs in
  # their turnover. It records what it was given. A list of exclusions would
  # imply the rest had been checked.
  test "a flat-rate return offers no tax advice" do
    entry(gross: 60_000, key: "sale_standard", account: accounts(:income_sales), side: :credit)

    assert_not flat(1450).key?(:flat_rate_caveats)
  end
end
