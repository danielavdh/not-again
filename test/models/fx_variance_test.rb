require "test_helper"

# The variance is the gap left when the two legs of a CROSS-CURRENCY TRANSFER
# are each converted into the display currency and no longer cancel.
#
# Only transfers, and only ever transfers: everything else in these books is
# single-currency by construction and converts nothing until a report is
# written, so nothing else can produce a variance at all. A large one therefore
# means one thing — money was exchanged at a rate well off the authority's.
#
# It could also mean a missing rate, while a leg that could not be converted
# contributed ZERO and the variance came out as the whole of the other leg: a
# €10,000 transfer reporting about £9,000 of variance.
class FxVarianceTest < ActiveSupport::TestCase
  setup do
    @admin  = admins(:sudo)
    @entity = entities(:family_biz)
    @gbp    = accounts(:bank_gbp)
    @eur    = accounts(:bank_eur)
    @month  = Date.new(2027, 3, 1)
    ExchangeRate.where(from_currency: %w[EUR GBP], to_currency: %w[EUR GBP]).delete_all
  end

  def transfer!(gbp_cents, eur_cents)
    je = JournalEntry.new(entry_date: @month + 10, memo: "sweep", posted: true)
    je.postings.build(account: @gbp, entry_type: :debit,  amount: gbp_cents)
    je.postings.build(account: @eur, entry_type: :credit, amount: eur_cents)
    je.save!
    je
  end

  def rate!(from, to, value, source: "ecb")
    ExchangeRate.create!(from_currency: from, to_currency: to, source: source, rate: value,
                         effective_date: @month, valid_from: @month, valid_to: @month.end_of_month)
  end

  def variance(source: "ecb")
    ExchangeRate.calculate_fx_variance(from_date: @month, to_date: @month.end_of_month,
                                       display_currency: "GBP", admin: @admin,
                                       entity_codes: [ @entity.code ], source: source)
  end

  # An exchange done at exactly the published rate leaves nothing behind.
  test "a transfer at the published rate shows no variance" do
    rate!("EUR", "GBP", 0.85)
    transfer!(85_000, 100_000)   # £850 out, €1000 in, at 0.85

    assert_equal 0, variance
  end

  # And one done at a worse rate shows the difference — which is the only thing
  # that should ever produce a figure here.
  test "a transfer away from the published rate shows the difference" do
    rate!("EUR", "GBP", 0.85)
    transfer!(83_000, 100_000)   # £830 for €1000: 0.83, not 0.85

    assert_equal(-2_000, variance, "£20 worse than the published rate")
  end

  # THE BUG. A leg with no rate used to score zero, so the variance became the
  # whole of the other leg. It must refuse to answer instead.
  test "a missing rate raises rather than inventing a variance" do
    transfer!(85_000, 100_000)   # no EUR->GBP rate exists at all

    error = assert_raises(ExchangeRate::RateUnavailable) { variance }
    assert_equal "EUR", error.from_currency
    assert_equal "GBP", error.to_currency
  end

  # The report reads one series; the variance must read the same one, or the two
  # halves of the page describe different reports.
  test "the variance uses the series it is given, not a re-derived preference" do
    rate!("EUR", "GBP", 0.85, source: "ecb")
    rate!("GBP", "EUR", 1.0 / 0.83, source: "hmrc")
    transfer!(85_000, 100_000)

    assert_equal 0, variance(source: "ecb")
    assert_not_equal 0, variance(source: "hmrc"),
                     "a different series must produce a different answer, not the same one"
  end

  def rows(source: "ecb")
    ExchangeRate.fx_variance_rows(from_date: @month, to_date: @month.end_of_month,
                                  display_currency: "GBP", admin: @admin,
                                  entity_codes: [ @entity.code ], source: source)
  end

  # The itemised rows and the single figure are the same method — they can
  # never disagree.
  test "fx_variance_rows sums to calculate_fx_variance" do
    rate!("EUR", "GBP", 0.85)
    transfer!(83_000, 100_000)
    transfer!(84_000, 100_000)

    assert_equal variance, rows.sum { |r| r[:variance_cents] }
    assert_equal 2, rows.size
  end

  # Each row carries the rate the amounts imply and the published one, so the
  # reader can see the spread the transfer cost them.
  test "a row shows the implied rate against the published one" do
    rate!("EUR", "GBP", 0.85)
    transfer!(83_000, 100_000)   # £830 for €1000 → implied 0.83

    row = rows.first
    assert_in_delta 0.83, row[:implied_rate], 0.0001
    assert_in_delta 0.85, row[:published_rate], 0.0001
    assert_equal(-2_000, row[:variance_cents])
    assert_equal "EUR", row[:from_currency]
    assert_equal "GBP", row[:to_currency]
  end

  # Ordinary entries cannot produce a variance, whatever their currency.
  test "a single-currency entry is not counted at all" do
    rate!("EUR", "GBP", 0.85)
    je = JournalEntry.new(entry_date: @month + 3, memo: "fee", posted: true)
    je.postings.build(account: @eur, entry_type: :debit,  amount: 50_000)
    je.postings.build(account: accounts(:income_sales), entry_type: :credit, amount: 50_000)
    je.save!

    assert_equal 0, variance, "a euro expense is a euro expense — nothing converts until a report"
  end
end
