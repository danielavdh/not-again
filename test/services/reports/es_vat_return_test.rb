# frozen_string_literal: true

require "test_helper"

# The Spanish Modelo 303, written to test the abstraction on a fourth shape:
# the devengado side pairs base and cuota per RATE, the deducible side per KIND
# of purchase, and a reverse charge wants its base on both sides — casilla 10
# AND casilla 36 — which no code can name twice. A feeder category carries it.
class Reports::EsVatReturnTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/es_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "es_vat" ])
    @date = Date.new(2026, 5, 15)
  end

  def code(key) = TaxCode.resolve(scheme: "es_vat", key: key, on: @date)

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
    Reports::VatReturn.new(entity: @entity, scheme: "es_vat",
                           from: Date.new(2026, 4, 1), to: Date.new(2026, 6, 30)).call
  end

  def box(res, key) = res[:boxes].find { |b| b.key == key }&.amount
  def casilla(res, number) = res[:boxes].find { |b| b.reference == number }&.amount

  test "a sale at 21 % fills casillas 07 and 09, and the cuota reaches 27" do
    entry(gross: 121_000, key: "venta_21", account: accounts(:income_sales), side: :credit)
    res = result

    assert_equal 100_000, casilla(res, "07"), "base imponible"
    assert_equal  21_000, casilla(res, "09"), "cuota"
    assert_equal  21_000, casilla(res, "27"), "total cuota devengada"
  end

  test "a purchase at 21 % fills 28 and 29, and the cuota reaches 45 and 46" do
    entry(gross: 121_000, key: "venta_21",  account: accounts(:income_sales),     side: :credit)
    entry(gross:  12_100, key: "compra_21", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 10_000, casilla(res, "28")
    assert_equal  2_100, casilla(res, "29")
    assert_equal  2_100, casilla(res, "45"), "total a deducir"
    assert_equal 21_000 - 2_100, casilla(res, "46"), "resultado régimen general"
    assert_equal casilla(res, "46"), casilla(res, "71"), "and the chain down to the resultado"
    assert_equal casilla(res, "71"), res[:net_payable]
  end

  # The base of an intra-EU acquisition is wanted in 10 (devengado) and in 36
  # (deducible). One code, one net — the feeder puts it in both.
  test "an intra-EU acquisition puts its base in 10 and 36, its cuota in 11 and 37" do
    entry(gross: 100_000, key: "adquisicion_intracomunitaria_21",
          account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 100_000, casilla(res, "10")
    assert_equal  21_000, casilla(res, "11")
    assert_equal 100_000, casilla(res, "36")
    assert_equal  21_000, casilla(res, "37")
    assert_equal 0, casilla(res, "46"), "owed and deducted in one return"
  end

  test "a reverse-charge service from outside the EU goes to 12/13 and 28/29" do
    entry(gross: 50_000, key: "compra_isp_21", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 50_000, casilla(res, "12")
    assert_equal 10_500, casilla(res, "13")
    assert_equal 50_000, casilla(res, "28")
    assert_equal 10_500, casilla(res, "29")
  end

  test "import VAT paid at customs is the cuota of 33 and nothing else" do
    entry(gross: 3_000, key: "importacion", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 3_000, casilla(res, "33")
    assert_equal 0,     casilla(res, "32"), "the customs value is not the app's to know"
  end

  test "exports, intra-EU supplies and non-subject services are information, not cuota" do
    entry(gross: 10_000, key: "venta_exportacion",       account: accounts(:income_sales), side: :credit)
    entry(gross: 20_000, key: "venta_intracomunitaria",  account: accounts(:income_sales), side: :credit)
    entry(gross: 30_000, key: "venta_no_sujeta",         account: accounts(:income_sales), side: :credit)
    res = result

    assert_equal 10_000, casilla(res, "60")
    assert_equal 20_000, casilla(res, "59")
    assert_equal 30_000, casilla(res, "120")
    assert_equal 0, casilla(res, "27")
  end

  test "the feeders never appear as casillas" do
    entry(gross: 100_000, key: "adquisicion_intracomunitaria_21",
          account: accounts(:expenses_general), side: :debit)
    refs = result[:boxes].map(&:reference)

    assert_not_includes result[:boxes].map(&:key), "aib_net"
    assert_not_includes result[:boxes].map(&:key), "isp_net"
    assert_includes refs, "10"
  end
end
