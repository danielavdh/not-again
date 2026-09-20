# frozen_string_literal: true
require "test_helper"
require "nokogiri"

# The last column of a report translates every currency into one, and is dropped
# when it would only repeat the column beside it — a single currency that
# already is the target. These tests render the real page and count cells,
# because the failure mode is a table one column out of step, which no unit test
# of the helper would catch.
class ReportCurrencyColumnsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(admins(:sudo))
    @entity = Entity.create!(code: "91", name: "One Currency", active: true)
    @group  = @entity.report_groups.create!(name: "Single")
    @report = @group.reports.create!(name: "R", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 12, 31))

    @income = Account.create!(code: "491001", name: "Fees", account_type: :income)
    @bank   = Account.create!(code: "191001", name: "Bank", account_type: :asset, currency: "GBP")
    @group.report_group_accounts.create!(account_id: @income.id, position: 1)

    je = JournalEntry.new(entry_date: Date.new(2026, 3, 1), posted: true, memo: "fee")
    je.postings.build(account: @income, entry_type: :credit, amount: 50_000)
    je.postings.build(account: @bank,   entry_type: :debit,  amount: 50_000, currency: "GBP")
    je.save!

    # These reports translate GBP into EUR, so they need a rate to exist.
    # Without one, a missing rate silently became 1.0, the pages rendered and
    # the column assertions passed — for entirely the wrong reason. A missing
    # rate now raises, and this line is what makes the tests test what they
    # claim to: column layout, not the fallback.
    #
    # ONE row for the whole year, which the validity span makes possible. The
    # ECB publishes EUR → X, and the GBP → EUR direction is derived from it.
    ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", rate: 0.85,
                              source: "ecb", effective_date: Date.new(2026, 1, 1),
                              valid_from: Date.new(2026, 1, 1), valid_to: Date.new(2026, 12, 31))
  end

  def rows_of(body, selector = "table.reports")
    table = Nokogiri::HTML(body).at(selector)
    table.css("tr")
         .reject { |tr| tr["class"].to_s.include?("separator") }
         .map { |tr| tr.element_children.select { |c| %w[td th].include?(c.name) }
                       .sum { |c| (c["colspan"] || 1).to_i } }
         .reject(&:zero?)
  end

  test "a single-currency report shows one amount column and no selector" do
    get report_url(@report, locale: :en, currency: "EUR")
    assert_response :success

    assert_select "#report-currency-select", { count: 0 },
                  "nothing to choose between with one currency"
    # account column + GBP. No EUR translation of a GBP-only report.
    assert_equal [ 2 ], rows_of(response.body).uniq,
                 "every row should be account + one currency"
    assert_no_match(/EUR/, Nokogiri::HTML(response.body).at("table.reports").at("thead").text)
  end

  test "rows stay in step when a second currency appears" do
    other = Account.create!(code: "491002", name: "EUR fees", account_type: :income)
    @group.report_group_accounts.create!(account_id: other.id, position: 2)
    eur_bank = Account.create!(code: "191002", name: "EUR bank", account_type: :asset, currency: "EUR")
    je = JournalEntry.new(entry_date: Date.new(2026, 4, 1), posted: true, memo: "eur fee")
    je.postings.build(account: other,    entry_type: :credit, amount: 20_000)
    je.postings.build(account: eur_bank, entry_type: :debit,  amount: 20_000, currency: "EUR")
    je.save!

    get report_url(@report, locale: :en, currency: "EUR")
    assert_response :success

    assert_select "#report-currency-select", { count: 1 },
                  "two currencies is a real choice, so the selector returns"
    # account + EUR + GBP + translated
    assert_equal [ 4 ], rows_of(response.body).uniq
  end

  # The trial balance carries TWO translating columns, debit and credit, so
  # getting it wrong puts every row two cells out of step rather than one.
  test "trial balance drops both translating columns for a single currency" do
    get trial_balance_reports_url(locale: :en, entities: @entity.code,
                                      start_date: "2026-01-01", end_date: "2026-12-31",
                                      currency: "EUR")
    assert_response :success

    assert_select "#report-currency-select", { count: 0 }
    counts = rows_of(response.body, "table")
    assert_equal 1, counts.uniq.size, "rows out of step: #{counts.tally.inspect}"
  end

  test "profit and loss rows stay in step for a single currency" do
    get profit_loss_reports_url(locale: :en, entities: @entity.code,
                                    start_date: "2026-01-01", end_date: "2026-12-31",
                                    currency: "EUR")
    assert_response :success
    assert_select "#report-currency-select", { count: 0 }
    counts = rows_of(response.body, "table")
    assert_equal 1, counts.uniq.size, "rows out of step: #{counts.tally.inspect}"
  end

  # The balance sheet's "current period net profit" line sits outside the
  # account
  # loops, so it was missed when the other cells were guarded.
  test "balance sheet rows stay in step for a single currency" do
    get balance_sheet_reports_url(locale: :en, entities: @entity.code,
                                      end_date: "2026-12-31", currency: "EUR")
    assert_response :success
    assert_select "#report-currency-select", { count: 0 }
    counts = rows_of(response.body, "table")
    assert_equal 1, counts.uniq.size, "rows out of step: #{counts.tally.inspect}"
  end
end
