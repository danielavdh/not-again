# frozen_string_literal: true
require "test_helper"

class Hmrc::TaxYearTest < ActiveSupport::TestCase
  TY = Hmrc::TaxYear

  test "label rolls over on 6 April" do
    assert_equal "2025-26", TY.label(Date.new(2026, 4, 5))   # last day of 2025-26
    assert_equal "2026-27", TY.label(Date.new(2026, 4, 6))   # first day of 2026-27
    assert_equal "2026-27", TY.label(Date.new(2026, 12, 31))
    assert_equal "2026-27", TY.label(Date.new(2027, 3, 31))
  end

  test "start_date is 6 April of the containing tax year" do
    assert_equal Date.new(2026, 4, 6), TY.start_date(Date.new(2026, 12, 31))
    assert_equal Date.new(2026, 4, 6), TY.start_date(Date.new(2027, 3, 31))
    assert_equal Date.new(2025, 4, 6), TY.start_date(Date.new(2026, 4, 5))
  end

  test "cumulative applies from 2025-26 onwards" do
    assert_not TY.cumulative?(Date.new(2025, 1, 1)) # 2024-25
    assert     TY.cumulative?(Date.new(2025, 4, 6)) # 2025-26
    assert     TY.cumulative?(Date.new(2026, 7, 1)) # 2026-27
  end
end
