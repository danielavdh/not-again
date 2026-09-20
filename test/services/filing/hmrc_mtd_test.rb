# frozen_string_literal: true
require "test_helper"

module Filing
  class HmrcMtdTest < ActiveSupport::TestCase
    setup do
      @entity = entities(:family_biz)
      @filing = HmrcMtd.new(entity: @entity, scheme: "gb_self_employment", admin: admins(:sudo))
    end

    # cumulative_start(quarter_start, quarter_end, obligations)

    test "cumulative model: start is the tax-year's earliest obligation, not the quarter" do
      obs = [
        { start_date: Date.new(2026, 4, 6),  end_date: Date.new(2026, 7, 5) },
        { start_date: Date.new(2026, 7, 6),  end_date: Date.new(2026, 10, 5) },
        { start_date: Date.new(2026, 10, 6), end_date: Date.new(2027, 1, 5) }
      ]
      # Submitting the Q3 period should cover 6 Apr 2026 → 5 Jan 2027
      # (cumulative)
      start_d = @filing.send(:cumulative_start, Date.new(2026, 10, 6), Date.new(2027, 1, 5), obs)
      assert_equal Date.new(2026, 4, 6), start_d
    end

    test "cumulative model honours a calendar-quarter election read from obligations" do
      obs = [{ start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30) }]
      start_d = @filing.send(:cumulative_start, Date.new(2026, 7, 1), Date.new(2026, 9, 30), obs)
      assert_equal Date.new(2026, 4, 1), start_d
    end

    test "cumulative model falls back to the 6 April boundary without obligations" do
      start_d = @filing.send(:cumulative_start, Date.new(2026, 10, 6), Date.new(2027, 1, 5), [])
      assert_equal Date.new(2026, 4, 6), start_d
    end

    test "pre-2025-26 stays per-quarter (start is the quarter start)" do
      obs = [{ start_date: Date.new(2024, 4, 6), end_date: Date.new(2024, 7, 5) }]
      start_d = @filing.send(:cumulative_start, Date.new(2024, 7, 6), Date.new(2024, 10, 5), obs)
      assert_equal Date.new(2024, 7, 6), start_d
    end
  end
end
