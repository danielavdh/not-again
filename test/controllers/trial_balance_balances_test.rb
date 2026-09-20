# frozen_string_literal: true
require "test_helper"

# A trial balance balances by definition. In a multi-currency ledger it only
# balances after translation IF the translation is accounted for, because each
# month is translated at that month's rate: the same foreign-currency credit is
# worth a different amount in January and in March. The difference is real and
# has to appear somewhere, or the report quietly claims debits and credits are
# equal when the numbers on screen are not.
#
# @fx_variance is the line that carries it, and this asks the only question that
# matters: does debits == credits + variance?
class TrialBalanceBalancesTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:two)
    # A FRESH entity, not a fixture one: the trial balance sums every account of
    # the entity, so fixture postings would drown the two entries under test and
    # the assertion would be measuring someone else's data.
    @entity = Entity.create!(code: "91", name: "FX Test Co", active: true)
    AdminEntity.create!(admin: @admin, entity: @entity, access_level: 0)

    sign_in_as(@admin)

    code   = @entity.code
    @bank  = Account.create!(code: "1#{code}950", name: "EUR bank",
                                  account_type: :asset, currency: "EUR")
    @sales = Account.create!(code: "4#{code}950", name: "EUR sales",
                                  account_type: :income)
  end

  # Two months, two DIFFERENT rates, so translation cannot be a no-op.
  def rate_on(date, rate)
    ExchangeRate.find_or_initialize_by(
      from_currency: "EUR", to_currency: "GBP", effective_date: date, source: "hmrc"
    ).update!(rate: rate)
  end

  def post_sale(date, cents)
    je = JournalEntry.new(entry_date: date, posted: true, memo: "EUR sale")
    je.postings.build(account: @bank,  entry_type: :debit,  amount: cents, currency: "EUR")
    je.postings.build(account: @sales, entry_type: :credit, amount: cents, currency: "EUR")
    je.save!
  end

  test "the trial balance balances once the FX variance is taken into account" do
    rate_on(Date.new(2026, 1, 1), 0.80)
    rate_on(Date.new(2026, 3, 1), 0.90)

    post_sale(Date.new(2026, 1, 15), 100_000)
    post_sale(Date.new(2026, 3, 15), 100_000)

    get trial_balance_reports_path(locale: :en,
                                       entities:   @entity.code,
                                       start_date: "2026-01-01",
                                       end_date:   "2026-12-31",
                                       currency:   "GBP")
    assert_response :success

    debit, credit, variance = totals_from_page

    assert_equal debit, credit + variance,
      "trial balance does not balance: debits #{debit}, credits #{credit}, " \
      "variance #{variance} — the difference of #{debit - credit - variance} " \
      "is translation the report is not disclosing"
  end

  # The same ledger in its own currency has nothing to translate, so it must
  # balance exactly with no variance at all. If this one fails, the problem is
  # not FX.
  test "a single-currency trial balance balances with no variance" do
    gbp_bank = Account.create!(code: "1#{@entity.code}951", name: "GBP bank",
                                    account_type: :asset, currency: "GBP")
    je = JournalEntry.new(entry_date: Date.new(2026, 2, 10), posted: true, memo: "GBP sale")
    je.postings.build(account: gbp_bank, entry_type: :debit,  amount: 50_000, currency: "GBP")
    je.postings.build(account: @sales,   entry_type: :credit, amount: 50_000, currency: "GBP")
    je.save!

    get trial_balance_reports_path(locale: :en,
                                       entities:   @entity.code,
                                       start_date: "2026-01-01",
                                       end_date:   "2026-12-31",
                                       currency:   "GBP")
    assert_response :success

    debit, credit, variance = totals_from_page
    assert_equal debit, credit
    assert_equal 0, variance
  end

  # Why the variance line is sufficient structurally rather than by luck.
  #
  # A nominal account has no currency of its own — a posting to one takes the
  # currency of the balance-sheet account in the same entry. So two currencies
  # can only ever meet between two BALANCE-SHEET accounts, which is precisely
  # the case calculate_fx_variance measures. An entry mixing currencies across a
  # nominal leg is not merely undisclosed: it cannot exist.
  test "a currency mismatch across a nominal leg cannot be created at all" do
    rate_on(Date.new(2026, 1, 1), 0.80)

    gbp_bank = Account.create!(code: "1#{@entity.code}952", name: "GBP bank",
                                    account_type: :asset, currency: "GBP")

    je = JournalEntry.new(entry_date: Date.new(2026, 1, 20), posted: true, memo: "EUR sale to GBP bank")
    je.postings.build(account: gbp_bank, entry_type: :debit,  amount: 80_000,  currency: "GBP")
    je.postings.build(account: @sales,   entry_type: :credit, amount: 100_000, currency: "EUR")

    refute je.valid?, "the ledger should refuse an entry whose legs do not balance"
    assert_includes je.errors.full_messages.join(" "), "balance"

    # And the nominal leg does not keep the currency it was handed.
    assert_not_equal "EUR", je.postings.last.currency,
      "a nominal posting takes its currency from the balance-sheet account"
  end

  private

  # assigns() lives in a gem this app does not carry, so read the report as a
  # person would — which is the honest test anyway: the question is whether the
  # numbers ON THE PAGE add up, not whether some ivar does.
  #
  # The totals row is tfoot tr.list-header, its last two cells the translated
  # debit and credit. The variance, when there is one, is a tr.fx-variance whose
  # non-empty trailing cell carries it.
  def totals_from_page
    footer = css_select("tfoot tr.list-header th").map { |th| cents(th.text) }
    debit, credit = footer.last(2)

    variance_cells = css_select("tr.fx-variance td").map(&:text).reject { |t| t.strip.empty? }
    variance = variance_cells.size > 1 ? cents(variance_cells.last) : 0

    [ debit.to_i, credit.to_i, variance ]
  end

  def cents(text)
    (text.to_s.gsub(/[^\d.\-]/, "").to_f * 100).round
  end
end
