# frozen_string_literal: true

require "test_helper"

# The table exists so a page that has been failing all week cannot go unnoticed.
# Two ways it could betray that: by becoming the second incident when something
# crashes in a loop, and by taking the request down with it.
class ErrorEventTest < ActiveSupport::TestCase
  def record(**overrides)
    ErrorEvent.record(**{ error_class: "ActiveRecord::RecordNotFound",
                          source: "ReportsController#show",
                          message: "Couldn't find Report",
                          path: "/en/reports/41",
                          line: "app/controllers/reports_controller.rb:88" }.merge(overrides))
  end

  test "a thousand of the same error in one day is one row, counted" do
    1000.times { record }

    assert_equal 1, ErrorEvent.count
    assert_equal 1000, ErrorEvent.sole.occurrences
  end

  test "the same error from a different place is its own row" do
    record
    record(source: "TaxExportJob")

    assert_equal 2, ErrorEvent.count
    assert_equal [ 1, 1 ], ErrorEvent.pluck(:occurrences)
  end

  test "yesterday's count is not added to today's" do
    record(at: 1.day.ago)
    record

    assert_equal 2, ErrorEvent.count
  end

  test "the newest message, path and line win — they are what you look at first" do
    record
    record(message: "second", path: "/en/reports/99", line: "app/models/report.rb:12")

    row = ErrorEvent.sole
    assert_equal 2, row.occurrences
    assert_equal "second", row.last_message
    assert_equal "/en/reports/99", row.last_path
    assert_equal "app/models/report.rb:12", row.last_line
  end

  # This runs while something is already going wrong. If it can raise, a broken
  # table turns every error into a second, worse one.
  test "a write that fails never reaches the caller" do
    ErrorEvent.stub(:upsert, ->(*) { raise ActiveRecord::StatementInvalid, "no such table" }) do
      assert_nothing_raised { record }
    end
  end

  test "an enormous message is cut, not stored whole" do
    record(message: "x" * 5000)

    assert_equal ErrorEvent::MAX_MESSAGE, ErrorEvent.sole.last_message.length
  end

  test "expired covers only rows past the retention window" do
    record(at: (ErrorEvent::RETENTION + 1.day).ago)
    record(at: 1.hour.ago, source: "Other#show")

    assert_equal 1, ErrorEvent.expired.count
    assert_equal "ReportsController#show", ErrorEvent.expired.sole.source
  end

  test "summary_since adds occurrences up per kind, not per row" do
    3.times { record }
    record(at: 1.day.ago)
    record(source: "TaxExportJob")

    summary = ErrorEvent.summary_since(7.days.ago)
    assert_equal 4, summary[[ "ActiveRecord::RecordNotFound", "ReportsController#show" ]]
    assert_equal 1, summary[[ "ActiveRecord::RecordNotFound", "TaxExportJob" ]]
  end
end
