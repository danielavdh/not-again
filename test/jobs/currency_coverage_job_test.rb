# frozen_string_literal: true
require "test_helper"
require "minitest/mock"

# THE FETCH THAT BREAKS THE DEADLOCK.
#
# Adding a currency fetched nothing, so the currency stayed empty and the screen
# said "no source — enter rates by hand" while the email said HMRC publishes it.
# Two separate faults, and fixing either alone leaves the other:
#
# · the sweep skipped periods that already held OTHER currencies (fixed in
# Rates::GapFinder — see its tests)
# · the sweep learns what a source publishes from its MOST RECENT stored period,
# which for a currency added today predates the currency. HMRC's latest period
# had no hryvnia, so the sweep would conclude HMRC does not publish it and never
# ask again.
#
# This job fetches the current period the moment a currency is added, which puts
# the new currency into that latest period, and the sweep takes the history from
# there. Neither half works without the other.
class CurrencyCoverageJobTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @admin = admins(:sudo)
    Currency.create!(code: "UAH", symbol: "₴")
    Currency.expire_cache
  end

  def run_job(coverage)
    fetched = []
    Rates::CoverageProbe.stub(:call, coverage) do
      Rates::Fetcher.stub(:fetch_and_store, ->(source, _date) {
        fetched << source
        { success: true, count: 4 }
      }) do
        CurrencyCoverageJob.perform_now(code: "UAH", admin_id: @admin.id, locale: "en")
      end
    end
    fetched
  end

  # Each source is asked for the period IT has, not for today's month. The ECB
  # month-end spot for August does not exist on the 21st, and the Bundesbank
  # average for August is computed on 3 September.
  test "each source is asked for the latest period it actually has" do
    asked = {}
    Rates::CoverageProbe.stub(:call, { "ecb" => true, "hmrc" => true }) do
      Rates::Fetcher.stub(:fetch_and_store, ->(source, date) { asked[source] = date; { success: true, count: 1 } }) do
        CurrencyCoverageJob.perform_now(code: "UAH", admin_id: @admin.id, locale: "en")
      end
    end

    assert_operator asked["ecb"], :<=, Date.current, "never a date that has not happened"
    assert_operator asked["hmrc"], :<=, Date.current
    assert_equal RateSourceConfig.fetch_date_for("ecb", RateSourceConfig.latest_available_period("ecb")), asked["ecb"]
  end

  test "it fetches from every source that publishes it" do
    fetched = run_job({ "hmrc" => true, "estv" => true, "ecb" => false, "bundesbank" => false })

    assert_equal %w[estv hmrc], fetched.sort,
                 "only the sources that just said yes, and each exactly once"
  end

  # Asking a feed for a currency it does not carry is the permanent false alarm
  # the whole design avoids.
  test "and asks nobody who does not" do
    assert_empty run_job({ "hmrc" => false, "estv" => false, "ecb" => false, "bundesbank" => false })
  end

  test "the admin still gets the answer either way" do
    assert_emails 1 do
      run_job({ "hmrc" => true, "ecb" => false, "estv" => false, "bundesbank" => false })
    end
  end

  # One unreachable feed must not lose the others, and the currency is added
  # regardless — the sweep picks it up once the feed is back.
  test "a feed that fails does not stop the rest" do
    attempted = []
    Rates::CoverageProbe.stub(:call, { "hmrc" => true, "estv" => true }) do
      Rates::Fetcher.stub(:fetch_and_store, ->(source, _date) {
        attempted << source
        raise "boom" if source == "estv"
        { success: true, count: 4 }
      }) do
        CurrencyCoverageJob.perform_now(code: "UAH", admin_id: @admin.id, locale: "en")
      end
    end

    assert_equal %w[estv hmrc], attempted.sort
  end
end
