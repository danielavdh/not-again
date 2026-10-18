# frozen_string_literal: true

require "test_helper"

# The Swiss MWST-Abrechnung, written to test the abstraction on two shapes at
# once: Ziffer 200 is the WORLDWIDE turnover from which the non-taxable parts
# are then deducted to reach 299, and the Saldosteuersatz method files the
# flat rate in a Ziffer of its own (323), not in the ordinary sales boxes.
class Reports::ChVatReturnTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/ch_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "ch_vat" ])
    @bank = Account.create!(code: "110090", name: "Bank CHF", account_type: :asset,
                            currency: "CHF", active: true)
    @date = Date.new(2026, 5, 15)
  end

  def code(key, on: @date) = TaxCode.resolve(scheme: "ch_vat", key: key, on: on)

  def entry(gross:, key:, account:, side:, date: @date)
    je = JournalEntry.new(entry_date: date, memo: key, posted: true)
    je.postings.build(account: account, entry_type: side, amount: gross,
                      tax_code_id: code(key, on: date).id)
    je.derive_tax_legs
    balance = je.postings.reject(&:marked_for_destruction?)
                .sum { |p| p.debit? ? p.amount.to_i : -p.amount.to_i }
    je.postings.build(account: @bank, entry_type: balance.positive? ? :credit : :debit,
                      amount: balance.abs, currency: "CHF")
    je.save!
  end

  def result(from: Date.new(2026, 4, 1), to: Date.new(2026, 6, 30), flat_rate_bps: nil)
    Reports::VatReturn.new(entity: @entity, scheme: "ch_vat", from: from, to: to,
                           flat_rate_bps: flat_rate_bps).call
  end

  def ziffer(res, number, which = nil)
    boxes = res[:boxes].select { |b| b.reference == number }
    box = which ? boxes.find { |b| b.label.end_with?(which) } : boxes.first
    box&.amount
  end

  test "a sale at 8,1 % reaches 200, 299 and both halves of 303" do
    entry(gross: 108_100, key: "verkauf_normal", account: accounts(:income_sales), side: :credit)
    res = result

    assert_equal 100_000, ziffer(res, "200"), "worldwide turnover"
    assert_equal 100_000, ziffer(res, "299"), "taxable turnover"
    assert_equal 100_000, ziffer(res, "303", "Leistungen")
    assert_equal   8_100, ziffer(res, "303", "Steuer")
    assert_equal   8_100, ziffer(res, "399")
  end

  # Exports and supplies abroad are IN 200 and then deducted, so 299 is only
  # what is taxable.
  test "an export is in 200, in 220, and gone from 299" do
    entry(gross: 108_100, key: "verkauf_normal", account: accounts(:income_sales), side: :credit)
    entry(gross:  50_000, key: "export",         account: accounts(:income_sales), side: :credit)
    res = result

    assert_equal 150_000, ziffer(res, "200")
    assert_equal  50_000, ziffer(res, "220")
    assert_equal  50_000, ziffer(res, "289")
    assert_equal 100_000, ziffer(res, "299")
  end

  test "input tax reaches 400 and 479, and 500 is what is owed" do
    entry(gross: 108_100, key: "verkauf_normal", account: accounts(:income_sales),     side: :credit)
    entry(gross:  10_810, key: "einkauf_normal", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 810, ziffer(res, "400")
    assert_equal 810, ziffer(res, "479")
    assert_equal 8_100 - 810, ziffer(res, "500")
    assert_equal ziffer(res, "500"), res[:net_payable]
  end

  test "a Bezugsteuer is declared in 383 and deducted in 400" do
    entry(gross: 10_000, key: "bezugsteuer", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 10_000, ziffer(res, "383", "Leistungen")
    assert_equal    810, ziffer(res, "383", "Steuer")
    assert_equal    810, ziffer(res, "400")
    assert_equal      0, ziffer(res, "500")
  end

  # The rates changed on 1 January 2024: one key, two rows, two Ziffern.
  test "a 2023 sale is at 7,7 % and files in 302, not 303" do
    entry(gross: 107_700, key: "verkauf_normal", account: accounts(:income_sales), side: :credit,
          date: Date.new(2023, 11, 1))
    res = result(from: Date.new(2023, 10, 1), to: Date.new(2023, 12, 31))

    assert_equal 100_000, ziffer(res, "302", "Leistungen")
    assert_equal   7_700, ziffer(res, "302", "Steuer")
    assert_nil ziffer(res, "303", "Steuer")&.nonzero?
  end

  # MWST-Info 12: the turnover INCLUDING tax times the Saldosteuersatz; no
  # input tax; Bezugsteuer declared at the statutory rate all the same. And it
  # files in 323, which the catalogue header names.
  test "under the Saldosteuersatz the tax is the rate on the gross turnover, filed in 323" do
    entry(gross: 108_100, key: "verkauf_normal", account: accounts(:income_sales),     side: :credit)
    entry(gross:  10_810, key: "einkauf_normal", account: accounts(:expenses_general), side: :debit)
    entry(gross:  10_000, key: "bezugsteuer",    account: accounts(:expenses_general), side: :debit)
    res = result(flat_rate_bps: 620)

    assert_equal 108_100, ziffer(res, "323", "Leistungen"), "turnover incl. tax"
    assert_equal   6_702, ziffer(res, "323", "Steuer"),     "6,2 % of it"
    assert_equal 0,   ziffer(res, "303", "Steuer"),         "not in the effective-method row"
    assert_equal 0,   ziffer(res, "400"),                   "no input tax under the Saldosteuersatz"
    assert_equal 810, ziffer(res, "383", "Steuer"),         "the Bezugsteuer is still declared"
    assert_equal 6_702 + 810, ziffer(res, "399")
    assert_equal 6_702 + 810, ziffer(res, "500")
    assert_equal "Saldosteuersatz", res[:flat_rate_label]
  end
end
