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

  # The same shape for the prepayment: the form takes an amount, the column
  # holds minor units.
  test "a prepayment typed on the form is stored in minor units and reads back" do
    assert_equal 5_000, Report.new(prepayment_display: "50").prepayment
    assert_equal 1_234, Report.new(prepayment_display: "12.34").prepayment
    assert_equal 12.34, Report.new(prepayment_display: "12.34").prepayment_display
    assert_nil Report.new(prepayment_display: "").prepayment
  end

  test "a negative prepayment is refused" do
    report = Report.new(prepayment: -1)
    report.valid?
    assert_includes report.errors.attribute_names, :prepayment
  end

  # The form hides the fields elsewhere; these are values sent anyway.
  test "a flat rate is refused on a scheme without one, accepted on GB and CH" do
    %w[de_vat nl_vat es_vat].each do |scheme|
      report = Report.new(report_group: ReportGroup.new(tax_scheme: scheme), flat_rate_bps: 1450)
      report.valid?
      assert_includes report.errors.attribute_names, :flat_rate_bps, scheme
    end
    %w[gb_vat ch_vat].each do |scheme|
      report = Report.new(report_group: ReportGroup.new(tax_scheme: scheme), flat_rate_bps: 1450)
      report.valid?
      assert_not_includes report.errors.attribute_names, :flat_rate_bps, scheme
    end
  end

  test "a prepayment is refused where the return has no box for it" do
    report = Report.new(report_group: ReportGroup.new(tax_scheme: "gb_vat"), prepayment: 5_000)
    report.valid?
    assert_includes report.errors.attribute_names, :prepayment

    report = Report.new(report_group: ReportGroup.new(tax_scheme: "de_vat"), prepayment: 5_000)
    report.valid?
    assert_not_includes report.errors.attribute_names, :prepayment
  end

  test "a rate outside any real scheme is refused" do
    report = Report.new(flat_rate_percentage: "150")
    report.valid?
    assert_includes report.errors.attribute_names, :flat_rate_bps
  end
end
