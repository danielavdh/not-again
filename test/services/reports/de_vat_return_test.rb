# frozen_string_literal: true

require "test_helper"

# The German return, written to test the ABSTRACTION on the hardest shape of the
# three: the UStVA has NO Kennzahl for output tax at 19 % or 7 %. You enter the
# net in 81 and 86, and ELSTER computes the tax. But Kz 83, the figure actually
# paid, is that same uncomputed tax less the Vorsteuer — so the tax has to exist
# somewhere the form never shows it.
class Reports::DeVatReturnTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/de_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "de_vat" ])
    @date = Date.new(2026, 5, 15)
  end

  def code(key) = TaxCode.resolve(scheme: "de_vat", key: key, on: @date)

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
    Reports::VatReturn.new(entity: @entity, scheme: "de_vat",
                           from: Date.new(2026, 4, 1), to: Date.new(2026, 6, 30)).call
  end

  def box(res, key) = res[:boxes].find { |b| b.key == key }&.amount

  test "a 19 % sale fills Kz 81 with the net and shows its tax in no box at all" do
    entry(gross: 119_000, key: "verkauf_19", account: accounts(:income_sales), side: :credit)
    res = result

    assert_equal 100_000, box(res, "umsatz_19"), "Kz 81, Bemessungsgrundlage"
    assert_nil res[:boxes].find { |b| b.amount == 19_000 && b.reference != "83" },
               "ELSTER computes the 19 % tax itself; no Kennzahl reports it"
    assert_equal 19_000, box(res, "zahllast"), "Kz 83 is that uncomputed tax"
  end

  test "an ordinary purchase reaches Kz 66 and no Bemessungsgrundlage" do
    entry(gross: 119_000, key: "einkauf_19", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 19_000, box(res, "vorsteuer_rechnungen"), "Kz 66"
    assert_equal(-19_000, box(res, "zahllast"), "Kz 83 is negative: a refund")
    assert_equal 0, box(res, "umsatz_19"),
                 "the UStVA has no Kennzahl for the value of an ordinary purchase"
  end

  test "Kz 83 is output tax less Vorsteuer across both rates" do
    entry(gross: 119_000, key: "verkauf_19", account: accounts(:income_sales),     side: :credit)
    entry(gross: 107_000, key: "verkauf_7",  account: accounts(:income_sales),     side: :credit)
    entry(gross:  59_500, key: "einkauf_19", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 100_000, box(res, "umsatz_19"), "Kz 81"
    assert_equal 100_000, box(res, "umsatz_7"),  "Kz 86"
    assert_equal   9_500, box(res, "vorsteuer_rechnungen"), "Kz 66"
    assert_equal  16_500, box(res, "zahllast"), "Kz 83 = 19.000 + 7.000 − 9.500"
  end

  # § 13b is the one place the Germans DO give the output tax a Kennzahl of its
  # own, 47 — and 67 deducts it again, so a reverse charge costs nothing.
  test "a 13b purchase owes in Kz 47 and deducts in Kz 67" do
    entry(gross: 100_000, key: "einkauf_13b", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 100_000, box(res, "leistungen_13b_bezogen"), "Kz 46, Bemessungsgrundlage"
    assert_equal  19_000, box(res, "steuer_13b"),             "Kz 47, Steuer"
    assert_equal  19_000, box(res, "vorsteuer_13b"),          "Kz 67, deducted again"
    assert_equal 0, box(res, "zahllast"), "Kz 83 nets to nothing"
  end

  # An intra-community acquisition splits the way 13b does, except its OUTPUT
  # tax has no Kennzahl either — only the net (89) and the deduction (61).
  test "an innergemeinschaftlicher Erwerb files its net in Kz 89 and its deduction in Kz 61" do
    entry(gross: 100_000, key: "ig_erwerb_19_code", account: accounts(:expenses_general), side: :debit)
    res = result

    assert_equal 100_000, box(res, "ig_erwerb_19"),        "Kz 89"
    assert_equal  19_000, box(res, "vorsteuer_ig_erwerb"), "Kz 61"
    assert_equal 0, box(res, "zahllast"), "Kz 83 nets to nothing"
  end

  test "an innergemeinschaftliche Lieferung is reported net and carries no tax" do
    entry(gross: 100_000, key: "verkauf_ig_lieferung", account: accounts(:income_sales), side: :credit)
    res = result

    assert_equal 100_000, box(res, "ig_lieferungen"), "Kz 41"
    assert_equal 0, box(res, "zahllast"), "Kz 83"
  end

  # Zeile 49: a filer with a Dauerfristverlängerung deducts the
  # Sondervorauszahlung fixed for the year in the last Voranmeldung. A figure
  # on the return, not a transaction — it comes from the report.
  test "the Sondervorauszahlung is shown in Kz 39 and taken off Kz 83" do
    entry(gross: 119_000, key: "verkauf_19", account: accounts(:income_sales), side: :credit)
    res = Reports::VatReturn.new(entity: @entity, scheme: "de_vat",
                                 from: Date.new(2026, 4, 1), to: Date.new(2026, 6, 30),
                                 prepayment: 5_000).call

    assert_equal 5_000,  box(res, "sondervorauszahlung"), "Kz 39"
    assert_equal 19_000 - 5_000, box(res, "zahllast"), "Kz 83"
    assert_equal box(res, "zahllast"), res[:net_payable], "and the summary agrees"
  end

  test "without a Sondervorauszahlung Kz 39 is simply zero" do
    assert_equal 0, box(result, "sondervorauszahlung")
  end

  test "every Kennzahl of the form appears, and no feeder does" do
    refs = result[:boxes].map(&:reference)

    assert_equal %w[81 86 35 36 41 43 48 60 21 45 89 93 95 98 46 47 84 85 66 61 62 67 39 83], refs,
                 "the computed-tax categories have no Kennzahl and must stay off the form"
  end
end
