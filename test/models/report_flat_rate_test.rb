# frozen_string_literal: true

require "test_helper"

# The form asks for a percentage; the column holds basis points. A version of
# this shipped briefly with the field bound straight to the bps column while the
# label said "%", so typing 14.5 would have filed a flat rate of 0.14%.
class ReportFlatRateTest < ActiveSupport::TestCase
  test "a percentage typed on the form is stored as basis points" do
    assert_equal 1450, Report.new(flat_rate_percentage: "14.5").flat_rate_bps
    assert_equal 1650, Report.new(flat_rate_percentage: "16.5").flat_rate_bps
    assert_equal 1200, Report.new(flat_rate_percentage: "12").flat_rate_bps
  end

  test "it reads back as the percentage the user typed" do
    assert_equal 14.5, Report.new(flat_rate_percentage: "14.5").flat_rate_percentage
  end

  test "blank means an ordinary return, not a zero rate" do
    assert_nil Report.new(flat_rate_percentage: "").flat_rate_bps
    assert_nil Report.new(flat_rate_percentage: nil).flat_rate_bps
  end

  test "a rate outside any real scheme is refused" do
    report = Report.new(flat_rate_percentage: "150")
    report.valid?
    assert_includes report.errors.attribute_names, :flat_rate_bps
  end
end
