# frozen_string_literal: true

require "test_helper"

# A VAT return is a saved Report like any other: you add it with a period, and
# clicking it shows the return for exactly that period. The group page lists
# the periods and nothing else — a VAT group has no accounts to assign.
class ReportsVatReturnTest < ActionDispatch::IntegrationTest
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "gb_vat" ])
    @group  = @entity.report_groups.create!(tax_scheme: "gb_vat", name: "GB-VAT")
    sign_in_as(admins(:two))

    code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: Date.new(2026, 7, 5))
    je = JournalEntry.new(entry_date: Date.new(2026, 7, 5), memo: "kit", posted: true)
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                      amount: 12_000, tax_code_id: code.id)
    je.derive_tax_legs
    je.postings.build(account: accounts(:bank_gbp), entry_type: :credit,
                      amount: 12_000, currency: "GBP")
    je.save!

    @q3 = @group.reports.create!(name: "Q3 2026",
                                 start_date: Date.new(2026, 7, 1),
                                 end_date:   Date.new(2026, 9, 30))
  end

  test "the report shows the return for its own period" do
    get report_path(@q3)

    assert_response :success
    assert_match "100.00", response.body, "the net reached box 7"
    assert_match "20.00",  response.body, "the VAT reached box 4"
  end

  # The period is the report's, so a report that does not span the entry shows
  # nothing — no date picker to get wrong.
  test "a report for another quarter shows nothing" do
    q2 = @group.reports.create!(name: "Q2 2026",
                               start_date: Date.new(2026, 4, 1),
                               end_date:   Date.new(2026, 6, 30))

    get report_path(q2)

    assert_response :success
    assert_no_match(/100\.00/, response.body)
  end

  test "the CSV comes from the report, where every other CSV does" do
    get report_path(@q3, format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match "100.00", response.body
  end

  test "the group page lists the periods and offers no account assignment" do
    get report_group_path(@group)

    assert_response :success
    assert_match "Q3 2026", response.body
    assert_select "select.tax-category-select", count: 0
  end

  # An income-tax group must still get its assignment page.
  test "an income-tax group still assigns accounts" do
    @entity.update!(tax_schemes: [ "gb_vat", "gb_self_employment" ])
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_self_employment_2026.yml"))
    income = @entity.report_groups.create!(tax_scheme: "gb_self_employment", name: "GB-SE")

    get report_group_path(income)

    assert_response :success
  end
end
