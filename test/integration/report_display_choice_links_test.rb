# frozen_string_literal: true
require "test_helper"
require "nokogiri"

# THE BUG THIS PREVENTS WAS INVISIBLE, and it produced a file that was
# internally consistent and quietly wrong.
#
# The converted column can be read at a chosen series — ?currency=CHF:estv — but
# every link OFF that page was built from @display_currency, the currency ALONE,
# so the source half was thrown away:
#
# · Download CSV → ?currency=CHF → tier 1 → ECB
# · short ⇄ long → ?currency=CHF → the choice silently reverted
#
# So picking CHF (ESTV) on screen and pressing Download gave a file built from
# ECB rates and labelled ecb — truthfully, because that is genuinely what
# answered the request the LINK made. Nothing looked broken from either end.
class ReportDisplayChoiceLinksTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(admins(:sudo))

    @entity = Entity.create!(code: "92", name: "Link Test", active: true)
    @group  = @entity.report_groups.create!(name: "Links")
    @report = @group.reports.create!(name: "R", start_date: Date.new(2026, 1, 1),
                                     end_date: Date.new(2026, 12, 31))

    income = Account.create!(code: "492001", name: "Fees", account_type: :income)
    bank   = Account.create!(code: "192001", name: "Bank", account_type: :asset, currency: "GBP")
    @group.report_group_accounts.create!(account_id: income.id, position: 1)

    je = JournalEntry.new(entry_date: Date.new(2026, 3, 1), posted: true, memo: "fee")
    je.postings.build(account: income, entry_type: :credit, amount: 50_000)
    je.postings.build(account: bank,   entry_type: :debit,  amount: 50_000, currency: "GBP")
    je.save!

    month = Date.new(2026, 3, 1)
    %w[ecb estv].each_with_index do |source, i|
      ExchangeRate.create!(from_currency: "GBP", to_currency: "CHF", source: source,
                                rate: 1.1 + i, effective_date: month,
                                valid_from: month, valid_to: month.end_of_month)
    end
  end

  def links_on(path)
    get path
    assert_response :success
    Nokogiri::HTML(response.body).css("a[href]").map { |a| a["href"] }
  end

  test "every link off the page carries the chosen source, not just the currency" do
    hrefs = links_on(report_path(@report, currency: "CHF:estv", locale: :en))

    carrying = hrefs.select { |h| h.include?("currency=CHF") }
    assert carrying.any?, "expected links back to this report"

    bare = carrying.reject { |h| h.include?("CHF%3Aestv") || h.include?("CHF:estv") }
    assert_empty bare,
                 "these dropped the chosen series: #{bare.inspect}"
  end

  test "the CSV link in particular" do
    hrefs = links_on(report_path(@report, currency: "CHF:estv", locale: :en))
    csv   = hrefs.find { |h| h.include?(".csv") }

    assert csv, "expected a CSV link"
    assert_match(/CHF(%3A|:)estv/, csv,
                 "downloading must build the file from the series shown on screen")
  end

  # A bare currency still works everywhere — every existing link and bookmark
  # sends one, and they must keep meaning "the usual source for that currency".
  test "a bare currency stays bare" do
    hrefs = links_on(report_path(@report, currency: "CHF", locale: :en))
    csv   = hrefs.find { |h| h.include?(".csv") }

    assert_match(/currency=CHF(&|$)/, csv, "no source was chosen, so none is invented")
  end
end
