# frozen_string_literal: true

require "test_helper"

# A reverse charge is the one VAT shape that can be paid out of an account in
# another currency: it posts nothing, so there is no leg that would have to be
# in the control account's currency. The return translates the net at the
# authority's accepted rate for the entry date, like every other figure in a tax
# report, and applies the rate to THAT — which is what the law says to do.
# Nothing is converted when the entry is saved.
class JournalEntryVatCurrencyTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "gb_vat" ])
    @date = Date.new(2026, 5, 15)
    @rc    = TaxCode.resolve(scheme: "gb_vat", key: "purchase_reverse_charge_services", on: @date)
    @plain = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: @date)
  end

  # HMRC's base IS sterling, so the published row is GBP → EUR and the other
  # direction is derived by inverting it: EUR 20.00 ÷ 1.25 = GBP 16.00.
  def hmrc_rate(rate, month: @date)
    ExchangeRate.where(source: "hmrc", from_currency: "GBP", to_currency: "EUR",
                       effective_date: month.beginning_of_month).delete_all
    ExchangeRate.create!(from_currency: "GBP", to_currency: "EUR", source: "hmrc",
                         rate: rate, effective_date: month.beginning_of_month,
                         valid_from: month.beginning_of_month, valid_to: month.end_of_month)
  end

  # The bank form's own sequence on a euro account.
  def euro_entry(code:, amount: 2_000, date: @date)
    je = JournalEntry.new(entry_date: date, memo: "foreign supplier", posted: true)
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                      amount: amount, tax_code_id: code.id)
    je.derive_tax_legs
    je.postings.build(account: accounts(:bank_eur), entry_type: :credit,
                      amount: amount, currency: "EUR")
    je
  end

  def return_for(month = @date)
    Reports::VatReturn.new(entity: @entity, scheme: "gb_vat",
                           from: month.beginning_of_month, to: month.end_of_month).call
  end

  def box(res, reference) = res[:boxes].find { |b| b.reference == reference }.amount

  test "a reverse charge may be paid from an account in another currency, and posts nothing" do
    je = euro_entry(code: @rc)
    assert je.save, je.errors.full_messages.join("; ")

    assert_equal 0, je.postings.count(&:tax_leg?)
    assert_equal [ "EUR" ], je.postings.filter_map(&:currency).uniq,
                 "no sterling anywhere in a euro entry"
  end

  test "the return translates the net at the authority's rate and takes the VAT from that" do
    hmrc_rate(1.25)
    euro_entry(code: @rc).save!
    res = return_for

    assert_equal 1_600, box(res, "7"), "EUR 20.00 at 1.25"
    assert_equal 1_600, box(res, "6"), "overseas services reach box 6 as well"
    assert_equal 320,   box(res, "1"), "20% of the sterling net, owed"
    assert_equal 320,   box(res, "4"), "and reclaimed"
    assert_equal 0,     res[:net_payable]
  end

  # One rate, one place: the net and its VAT cannot drift apart, because the
  # VAT is computed from the translated net rather than stored beside it.
  test "a rate corrected afterwards moves the net and the VAT together" do
    hmrc_rate(1.25)
    euro_entry(code: @rc).save!
    hmrc_rate(2.5)
    res = return_for

    assert_equal 800, box(res, "7")
    assert_equal 160, box(res, "1")
    assert_equal 160, box(res, "4")
  end

  # The per-account table is what an accountant reads to check the boxes, so it
  # has to reconcile to them.
  test "the per-account breakdown reconciles to the boxes it explains" do
    hmrc_rate(1.25)
    euro_entry(code: @rc).save!
    res  = return_for
    line = res[:account_lines].find { |l| l.account_code == accounts(:expenses_general).code }

    assert_equal box(res, "7"), line.net
    assert_equal box(res, "4"), line.tax
  end

  test "a month with no accepted rate is an error, not a figure from another series" do
    ExchangeRate.where(source: "hmrc", from_currency: "GBP", to_currency: "EUR").delete_all
    euro_entry(code: @rc).save!

    assert_raises(ExchangeRate::RateUnavailable) { return_for }
  end

  # One leg has nothing to cancel against, so it would have to be posted in
  # sterling inside a euro entry, which a control account cannot hold. Refused
  # with a message that names the currencies, not left to fail as "must
  # balance".
  test "an ordinary VAT code is still refused on an entry in another currency" do
    je = euro_entry(code: @plain)

    assert_not je.save
    assert je.errors[:base].any? { |m|
      m.include?(TaxSchemeConfig.scheme_label("gb_vat")) && m.include?("EUR")
    }, "expected the code rule to refuse it by name, got: #{je.errors[:base].inspect}"
  end
end
