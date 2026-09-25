# frozen_string_literal: true
require "test_helper"

# Cleaning up a scheme means taking its accounts away, and a saved report of
# that scheme survives the accounts it was about. That report still has to open
# — it is how you read what it said, and the page you delete it from. It used to
# 500, because TaxReport#empty_result returned a smaller hash than #build and the
# view reads :net unconditionally.
class EmptyGroupReportTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:two)
    sign_in_as(@admin)
    @entity = entities(:family_biz)
  end

  test "a report whose group has lost every account still opens" do
    group  = ReportGroup.create!(name: "Emptied", entity: @entity)
    report = group.reports.create!(name: "Orphan", start_date: Date.new(2026, 1, 1),
                                   end_date: Date.new(2026, 3, 31))

    get report_url(report, locale: :en)
    assert_response :success
  end

  test "a TAX report whose scheme has no accounts still opens" do
    group  = ReportGroup.create!(name: "Emptied tax", entity: @entity, tax_scheme: "gb_self_employment")
    report = group.reports.create!(name: "Orphan tax", start_date: Date.new(2026, 4, 6),
                                   end_date: Date.new(2026, 7, 5))

    get report_url(report, locale: :en)
    assert_response :success

    # and can still be read as CSV, and deleted
    get report_url(report, format: :csv, locale: :en)
    assert_response :success

    assert_difference -> { Report.count }, -1 do
      delete report_url(report, locale: :en)
    end
  end
end
