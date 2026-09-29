# frozen_string_literal: true
require "test_helper"
require "minitest/mock"

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

    # ==================== the quarterly period type election ====================
    #
    # HMRC's own online services cannot set this, so software is the only route.
    # They enforce the locking rules server-side; the point of doing it here too
    # is that a customer is TOLD rather than meeting a live rejection.

    OPEN      = Base::STATUS_OPEN
    FULFILLED = Base::STATUS_FULFILLED

    def choice_for(obligations, details)
      @filing.stub(:group, Struct.new(:business_id, :id, :display_name).new("XBIS123", 1, "SE")) do
        @filing.stub(:raw_business_details, details) do
          @filing.send(:quarterly_choice, obligations)
        end
      end
    end

    def open_quarter(year = 2026)
      [ { start_date: Date.new(year, 4, 6), end_date: Date.new(year, 7, 5), status: OPEN } ]
    end

    test "with nothing filed yet the election is offered, naming the tax year and current value" do
      choice = choice_for(open_quarter, { "quarterlyTypeChoice" => { "quarterlyPeriodType" => "standard" } })

      assert_nil choice[:locked_by], "an unfiled tax year must remain electable"
      assert_equal "2026-27", choice[:tax_year]
      assert_equal "standard", choice[:current]
      assert_equal %w[standard calendar], choice[:options]
    end

    # HMRC locks the choice once the tax year has a submission. Offering the
    # control anyway would send a request they refuse.
    test "a fulfilled obligation locks the election for that tax year" do
      obs = open_quarter + [ { start_date: Date.new(2026, 7, 6), end_date: Date.new(2026, 10, 5), status: FULFILLED } ]
      choice = choice_for(obs, { "quarterlyTypeChoice" => { "quarterlyPeriodType" => "calendar" } })

      assert_equal :submitted, choice[:locked_by]
    end

    # Their second rule: a business that commenced 1-5 April, while today is
    # still inside that window and later than the commencement date.
    test "the 1-5 April commencement window locks it, and only within the window" do
      details = { "commencementDate" => "2026-04-02" }

      travel_to Date.new(2026, 4, 4) do
        assert_equal :commencement_window, choice_for(open_quarter, details)[:locked_by]
      end
      travel_to Date.new(2026, 4, 2) do
        assert_nil choice_for(open_quarter, details)[:locked_by],
                   "on the commencement date itself HMRC's rule does not bite"
      end
      travel_to Date.new(2026, 6, 1) do
        assert_nil choice_for(open_quarter, details)[:locked_by],
                   "outside April the window is irrelevant"
      end
    end

    test "an ordinary commencement date does not lock anything" do
      travel_to Date.new(2026, 4, 3) do
        assert_nil choice_for(open_quarter, { "commencementDate" => "2019-09-01" })[:locked_by]
      end
    end

    # Nothing to decide about: no business chosen, or HMRC's record unreadable.
    # The panel renders no control at all rather than an empty one.
    test "no business id and no record mean no election is offered" do
      assert_nil @filing.stub(:group, nil) { @filing.send(:quarterly_choice, open_quarter) }
      assert_nil choice_for(open_quarter, nil)
    end

    # The tax year is NOT taken from the form: a stale page must not elect for a
    # year nobody was looking at.
    test "the election sends the tax year of the obligations, and the chosen type" do
      sent = nil
      client = Object.new
      client.define_singleton_method(:obligations) { |**| [ { start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5), status: Base::STATUS_OPEN } ] }
      client.define_singleton_method(:set_quarterly_period_type) { |**kwargs| sent = kwargs }

      @filing.stub(:client, client) do
        @filing.stub(:group, Struct.new(:business_id).new("XBIS123")) do
          @filing.stub(:raw_business_details, { "quarterlyTypeChoice" => { "quarterlyPeriodType" => "standard" } }) do
            assert_equal "2026-27", @filing.set_quarterly_period_type("calendar")
          end
        end
      end

      assert_equal({ business_id: "XBIS123", tax_year: "2026-27", type: "calendar" }, sent)
    end

    test "a locked tax year refuses before anything is sent" do
      client = Object.new
      client.define_singleton_method(:obligations) { |**| [ { start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5), status: Base::STATUS_FULFILLED } ] }
      client.define_singleton_method(:set_quarterly_period_type) { |**| flunk "nothing may be sent for a locked tax year" }

      @filing.stub(:client, client) do
        @filing.stub(:group, Struct.new(:business_id).new("XBIS123")) do
          @filing.stub(:raw_business_details, { "commencementDate" => "2019-01-01" }) do
            assert_raises(Base::SettingLocked) { @filing.set_quarterly_period_type("calendar") }
          end
        end
      end
    end

    test "an unknown type is refused, whatever HMRC might do with it" do
      client = Object.new
      client.define_singleton_method(:obligations) { |**| [] }
      client.define_singleton_method(:set_quarterly_period_type) { |**| flunk "nothing may be sent for an unknown type" }

      @filing.stub(:client, client) do
        @filing.stub(:group, Struct.new(:business_id).new("XBIS123")) do
          @filing.stub(:raw_business_details, {}) do
            assert_raises(ArgumentError) { @filing.set_quarterly_period_type("monthly") }
          end
        end
      end
    end

    test "pre-2025-26 stays per-quarter (start is the quarter start)" do
      obs = [{ start_date: Date.new(2024, 4, 6), end_date: Date.new(2024, 7, 5) }]
      start_d = @filing.send(:cumulative_start, Date.new(2024, 7, 6), Date.new(2024, 10, 5), obs)
      assert_equal Date.new(2024, 7, 6), start_d
    end
  end
end
