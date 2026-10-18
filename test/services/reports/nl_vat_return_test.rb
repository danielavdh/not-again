# frozen_string_literal: true

require "test_helper"

# The Dutch return, built to test the ABSTRACTION rather than the tax: it is
# shaped differently from the UK's in two ways, and both had to work without
# touching Reports::VatReturn.
#
#   1. Net and VAT are paired per rubriek — 1a carries its own omzet AND its own
#      btw, where the UK puts every net in box 6 and every output VAT in box 1.
#   2. There is no box for the net of ordinary purchases. Only 5b, the tax.
class Reports::NlVatReturnTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/nl_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "nl_vat" ])
    @date = Date.new(2026, 5, 15)
  end

  def code(key) = TaxCode.resolve(scheme: "nl_vat", key: key, on: @date)

  # The bank form's sequence, in EUR because a code may only be used on an entry
  # in its scheme's own currency.
  def entry(gross:, key:, account:, side:)
    je = JournalEntry.new(entry_date: @date, memo: key, posted: true)
    je.postings.build(account: account, entry_type: side, amount: gross, tax_code_id: code(key).id)
    je.derive_tax_legs
    balance = je.postings.reject(&:marked_for_destruction?)
                .sum { |p| p.debit? ? p.amount.to_i : -p.amount.to_i }
    je.postings.build(account: accounts(:bank_eur),
                      entry_type: balance.positive? ? :credit : :debit,
                      amount: balance.abs, currency: "EUR")
    je.save!
  end

  def result
    Reports::VatReturn.new(entity: @entity, scheme: "nl_vat",
                           from: Date.new(2026, 4, 1), to: Date.new(2026, 6, 30)).call
  end

  def box(res, key) = res[:boxes].find { |b| b.key == key }&.amount

  test "a sale at the high rate fills 1a's own omzet and btw" do
    entry(gross: 121_000, key: "verkoop_hoog", account: accounts(:income_sales), side: :credit)
    res = result

    assert_equal 100_000, box(res, "turnover_high"), "1a omzet"
    assert_equal  21_000, box(res, "vat_high"),      "1a btw — in its OWN rubriek, not a shared box"
    assert_equal  21_000, box(res, "vat_owed"),      "5a"
  end

  test "an ordinary purchase reaches 5b and no turnover box at all" do
    entry(gross: 121_000, key: "inkoop_hoog", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 21_000, box(res, "vat_input"), "5b"
    assert_equal(-21_000, box(res, "vat_payable"), "5c is 5a less 5b")
    assert_nil res[:boxes].find { |b| b.reference.to_s.start_with?("1") && !b.amount.zero? },
               "the Dutch form has no box for the value of an ordinary purchase"
  end

  test "5a totals the rubrieken the Belastingdienst says it does" do
    entry(gross: 121_000, key: "verkoop_hoog", account: accounts(:income_sales),     side: :credit)
    entry(gross: 109_000, key: "verkoop_laag", account: accounts(:income_sales),     side: :credit)
    entry(gross:  60_500, key: "inkoop_hoog",  account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 21_000, box(res, "vat_high"), "1a"
    assert_equal  9_000, box(res, "vat_low"),  "1b"
    assert_equal 30_000, box(res, "vat_owed"), "5a = 1a + 1b"
    assert_equal 10_500, box(res, "vat_input"), "5b"
    assert_equal 19_500, box(res, "vat_payable"), "5c"
  end

  # Verlegd naar u: owed in 2a and deducted in 5b at once, so it costs nothing
  # and both halves still appear.
  test "a domestic verlegging owes in 2a and deducts in 5b" do
    entry(gross: 100_000, key: "inkoop_verlegd_binnenland",
          account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 100_000, box(res, "turnover_rc_inland"), "2a omzet"
    assert_equal  21_000, box(res, "vat_rc_inland"),      "2a btw"
    assert_equal  21_000, box(res, "vat_input"),          "5b, the other half"
    assert_equal 0, box(res, "vat_payable"), "5c nets to nothing"
  end

  # The supplier's side goes to 1e, not rubriek 2 — the Belastingdienst puts
  # "het bedrag waarover de btw is verlegd" there.
  test "the supplier's side of a verlegging lands in 1e" do
    entry(gross: 100_000, key: "verkoop_verlegd_binnenland",
          account: accounts(:income_sales), side: :credit)
    res = result

    assert_equal 100_000, box(res, "turnover_zero_or_not_taxed"), "1e"
    assert_equal 0, box(res, "vat_owed"), "no btw is charged on it"
  end

  test "every rubriek of the form is present, in the Belastingdienst's order" do
    refs = result[:boxes].map(&:reference)

    assert_equal %w[1a 1a 1b 1b 1c 1c 1d 1d 1e 2a 2a 3a 3b 3c 4a 4a 4b 4b 5a 5b 5c], refs,
                 "a rubriek carrying both omzet and btw is two lines sharing one number"
  end
end
