# frozen_string_literal: true
require "test_helper"

# The figures on the bottom line of a financial statement.
#
# Three of them were arithmetic inside the ERB — the balance sheet's
# liabilities+equity and net profit, and the P&L's net per currency — which
# meant they could not be tested without rendering, and nothing did. They come
# out of calculate_*_totals now, and these tests pin what they must equal.
#
# The assertions are identities rather than magic numbers on purpose: a total
# that does not equal the sum of its parts is wrong whatever the fixture data
# happens to be.
class ReportTotalsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:two)
    # A fresh entity: these are whole-statement totals, and fixture postings
    # would drown the entries under test.
    @entity = Entity.create!(code: "92", name: "Totals Test Co", active: true)
    AdminEntity.create!(admin: @admin, entity: @entity, access_level: 0)

    sign_in_as(@admin)

    code    = @entity.code
    @bank   = Account.create!(code: "1#{code}160", name: "GBP bank",   account_type: :asset,     currency: "GBP")
    @loan   = Account.create!(code: "2#{code}160", name: "GBP loan",   account_type: :liability, currency: "GBP")
    @equity = Account.create!(code: "3#{code}160", name: "GBP equity", account_type: :equity,    currency: "GBP")
    @sales  = Account.create!(code: "4#{code}160", name: "Sales",      account_type: :income)
    @costs  = Account.create!(code: "5#{code}160", name: "Costs",      account_type: :expense)
  end

  def post_entry(debit:, credit:, cents:, date: Date.new(2026, 3, 1), currency: "GBP")
    je = JournalEntry.new(entry_date: date, posted: true, memo: "test")
    je.postings.build(account: debit,  entry_type: :debit,  amount: cents, currency: currency)
    je.postings.build(account: credit, entry_type: :credit, amount: cents, currency: currency)
    je.save!
  end

  def cents(text)
    (text.to_s.gsub(/[^\d.\-]/, "").to_f * 100).round
  end

  # The last cell of the statement row whose first cell reads exactly `label`.
  # Every subtotal and total on these statements is a labelled row, so this
  # picks a figure out without depending on which tag or row class carries it.
  def figure(label)
    row = css_select("tr").find { |r| r.css("td,th").first&.text&.squish == label }
    assert row, "no statement row labelled #{label.inspect}"
    cents(row.css("td,th").last.text)
  end

  # --- balance sheet -------------------------------------------------------

  test "total liabilities and equity is the sum of the two lines above it" do
    post_entry(debit: @bank,   credit: @loan,   cents: 300_00)
    post_entry(debit: @bank,   credit: @equity, cents: 200_00)

    get balance_sheet_reports_path(locale: :en, entities: @entity.code,
                                       end_date: "2026-12-31", currency: "GBP")
    assert_response :success

    liabilities = figure("Total Liabilities")
    equity      = figure("Total Equity")
    combined    = figure("Total Liabilities + Equity")

    assert_equal 500_00, combined, "liabilities + equity should be the total posted"
    assert_equal liabilities + equity, combined,
      "the footer total does not equal the two subtotals printed above it"
  end

  test "net profit is assets minus liabilities and equity" do
    post_entry(debit: @bank, credit: @loan,   cents: 300_00)
    post_entry(debit: @bank, credit: @equity, cents: 200_00)
    # Trading profit: an asset that no liability or equity line claims.
    post_entry(debit: @bank, credit: @sales,  cents: 150_00)

    get balance_sheet_reports_path(locale: :en, entities: @entity.code,
                                       end_date: "2026-12-31", currency: "GBP")
    assert_response :success

    assets     = figure("Total Assets")
    combined   = figure("Total Liabilities + Equity")
    net_profit = figure("Current Period Net Profit / (Loss)")

    assert_equal 150_00, net_profit, "the trading profit should be what neither liabilities nor equity claims"
    assert_equal assets - combined, net_profit
  end

  test "a balance sheet with no profit shows a zero net profit rather than a blank" do
    post_entry(debit: @bank, credit: @equity, cents: 400_00)

    get balance_sheet_reports_path(locale: :en, entities: @entity.code,
                                       end_date: "2026-12-31", currency: "GBP")
    assert_response :success

    assert_equal 0, figure("Current Period Net Profit / (Loss)")
  end

  # --- profit and loss -----------------------------------------------------

  test "net profit is income minus expense" do
    post_entry(debit: @bank,  credit: @sales, cents: 900_00)
    post_entry(debit: @costs, credit: @bank,  cents: 350_00)

    get profit_loss_reports_path(locale: :en, entities: @entity.code,
                                     start_date: "2026-01-01", end_date: "2026-12-31",
                                     currency: "GBP")
    assert_response :success

    net = cents(css_select("tfoot tr.list-header th").last.text)
    assert_equal 550_00, net
  end

  test "a loss is shown as a negative net, not dropped" do
    post_entry(debit: @bank,  credit: @sales, cents: 100_00)
    post_entry(debit: @costs, credit: @bank,  cents: 250_00)

    get profit_loss_reports_path(locale: :en, entities: @entity.code,
                                     start_date: "2026-01-01", end_date: "2026-12-31",
                                     currency: "GBP")
    assert_response :success

    assert_equal(-150_00, cents(css_select("tfoot tr.list-header th").last.text))
  end

  test "a period with nothing in it still renders a net of zero" do
    get profit_loss_reports_path(locale: :en, entities: @entity.code,
                                     start_date: "2026-01-01", end_date: "2026-12-31",
                                     currency: "GBP")
    assert_response :success
  end

  # --- trial balance: translation rounding (audit M10) --------------------

  # Each translated column is a sum of per-account figures rounded one at a
  # time, so the two need not tie even when the entry balances exactly in its
  # own currency. That residual is folded into the FX-variance line, and the
  # ADJUSTED totals must then balance to the penny.
  test "a translated trial balance's adjusted totals balance despite per-account rounding" do
    code = @entity.code
    eur_bank = Account.create!(code: "1#{code}200", name: "EUR bank", account_type: :asset,   currency: "EUR")
    exp_a    = Account.create!(code: "5#{code}201", name: "Rent",     account_type: :expense)
    exp_b    = Account.create!(code: "5#{code}202", name: "Rates",    account_type: :expense)
    # One flat rate for every currency the books use, so source_for_span finds
    # a series that covers the whole period — otherwise translation is skipped.
    ExchangeRate.delete_all
    Currency.where.not(code: "GBP").pluck(:code).each do |c|
      (2024..2027).each do |y|
        (1..12).each do |m|
          ExchangeRate.create!(from_currency: c, to_currency: "GBP", source: "hmrc", rate: 0.7,
                               effective_date: Date.new(y, m, 1),
                               valid_from: Date.new(y, m, 1), valid_to: Date.new(y, m, -1))
        end
      end
    end

    # A GBP leg too, so the trial balance has more than one currency and the
    # translating column appears at all.
    post_entry(debit: @bank, credit: @equity, cents: 1_000_00)

    # Debit side split 5005 + 5005, credit side one leg of 10010 — same EUR
    # total, but 2·round(5005·r) need not equal round(10010·r).
    je = JournalEntry.new(entry_date: Date.new(2026, 3, 10), posted: true, memo: "split")
    je.postings.build(account: exp_a,    entry_type: :debit,  amount: 5_005)
    je.postings.build(account: exp_b,    entry_type: :debit,  amount: 5_005)
    je.postings.build(account: eur_bank, entry_type: :credit, amount: 10_010, currency: "EUR")
    je.save!

    get trial_balance_reports_path(locale: :en, entities: code, end_date: "2026-12-31", currency: "GBP")
    assert_response :success

    adjusted = css_select("tfoot tr").find { |r| r.css("th,td").first&.text&.squish&.match?(/adjusted/i) }
    assert adjusted, "no ADJUSTED TOTALS row — the FX-variance block did not render"
    figures = adjusted.css("th,td").map(&:text).select { |t| t.match?(/\d/) }.map { |t| cents(t) }
    assert_equal 2, figures.size, "expected an adjusted debit and an adjusted credit"
    assert_equal figures.first, figures.last, "adjusted debit and credit must be equal"
  end
end
