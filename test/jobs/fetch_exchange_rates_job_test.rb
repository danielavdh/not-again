# frozen_string_literal: true
require "test_helper"

# The alarm. A rate source breaking is silent by nature: nothing errors, no page
# fails, and the first symptom is a report months later with a figure missing —
# or, before RateUnavailable, quietly converted at 1.0.
#
# Publishers move things: HMRC's own files want an UNPADDED month (2026-8) and
# the Bundesbank's API a padded one (2026-06). Either could change without
# telling anyone, and the job has to shout when it does.
class FetchExchangeRatesJobTest < ActiveSupport::TestCase
  setup { @job = FetchExchangeRatesJob.new }

  # NOT `failures` — Minitest::Test defines that as the list of a test's own
  # failures, and shadowing it means the framework calls yours with no
  # arguments.
  def problems_in(result)
    @job.send(:failures_in, result)
  end

  # THE BUG THIS FILE EXISTS FOR. fetch_and_store! returns one result PER SOURCE
  # — { "ecb" => {...}, ... } — so reading result[:success] and result[:error]
  # on that outer hash finds nil on both. One source failing in the nightly all-
  # sources run then raised nothing and emailed nobody, indefinitely.
  test "a single failing source in a multi-source run is caught and named" do
    result = { "ecb"  => { success: true, count: 3 },
               "hmrc" => { success: false, error: "format changed" } }

    problems = problems_in(result)
    assert_equal 1, problems.size, "one broken source must not hide behind a working one"
    assert_match(/hmrc/, problems.first, "the failure must name which source broke")
    assert_match(/format changed/, problems.first)
  end

  test "every failing source is named, not just the first" do
    result = { "ecb"        => { success: false, error: "404" },
               "hmrc"       => { success: true },
               "bundesbank" => { success: false, error: "unreadable" } }

    assert_equal 2, problems_in(result).size
  end

  test "an all-healthy run raises nothing" do
    assert_empty problems_in({ "ecb" => { success: true }, "hmrc" => { success: true, count: 3 } })
  end

  # A month-average source is legitimately empty until its month ends. Treating
  # that as a failure would email sudo on the 1st of every month until they
  # stopped reading the emails, which is worse than no alarm at all.
  test "a period that is not published yet is not a failure" do
    assert_empty problems_in({ success: true, count: 0, not_published: true })
    assert_empty problems_in({ "bundesbank" => { success: true, count: 0, not_published: true } })
  end

  test "the single-source shape is still caught" do
    assert_equal [ "boom" ], problems_in({ success: false, error: "boom" })
    assert_empty problems_in({ success: true, count: 3 })
  end

  # The distinction that keeps the alarm trustworthy: "I could not read this"
  # is worth waking someone for; "there is nothing here yet" is not.
  test "an unrecognised response is a failure, and says the publisher may have changed it" do
    Rates::Fetcher.stub(:fetch_url, "not the feed you are looking for") do
      result = Rates::Fetcher.fetch_and_store("hmrc", Date.new(2026, 8, 1))

      assert_equal false, result[:success]
      assert_match(/did not match the expected format/, result[:error])
      assert_match(/publisher may have changed/, result[:error])
      assert_equal 1, problems_in(result).size
    end
  end

  test "a source that cannot be fetched at all is a failure" do
    Rates::Fetcher.stub(:fetch_url, nil) do
      result = Rates::Fetcher.fetch_and_store("hmrc", Date.new(2026, 8, 1))
      assert_equal false, result[:success]
      assert_equal 1, problems_in(result).size
    end
  end

  # Every source in the registry must be reachable by name, or the nightly run
  # would skip it in silence.
  test "every declared source can be fetched by name" do
    RateSourceConfig.all.each do |source|
      result = Rates::Fetcher.stub(:fetch_url, nil) do
        Rates::Fetcher.fetch_and_store(source, Date.current)
      end
      assert_no_match(/unknown source/, result[:error].to_s,
                      "#{source} is declared but the fetcher does not know it")
    end
  end
  # FETCH WHAT IS NEEDED, NOT WHAT IS DECLARED.
  #
  # config/recurring.yml holds one entry per source. Without this guard, adding
  # a source to the registry means EVERY installation pulls it nightly for ever,
  # for countries it has never heard of. ecb_daily is the case that forces it:
  # it exists for the Netherlands and Spain, and it is ~250 periods a year
  # rather than 12.
  #
  # Deliberately the same method the gap-filler uses, so a schedule and a sweep
  # can never disagree about what is wanted.

  # `enabled?` is FALSE outside production, so perform returns before reaching
  # anything worth testing. Both of these passed vacuously without this, and the
  # negative one passed while asserting nothing at all — the worse half, because
  # a green test that exercises no code reads as coverage.
  def running_the_job(source, wanted:)
    fetched = false
    Rates::Fetcher.stub(:enabled?, true) do
      Rates::GapFinder.stub(:wanted?, wanted) do
        Rates::Fetcher.stub(:fetch_and_store, ->(*) { fetched = true; { success: true } }) do
          FetchExchangeRatesJob.perform_now(source)
        end
      end
    end
    fetched
  end

  test "a scheduled fetch of a source nothing wants does nothing" do
    assert_not running_the_job("ecb_daily", wanted: false),
               "no rule names it and no report displays through it"
  end

  test "a scheduled fetch of a wanted source proceeds" do
    assert running_the_job("hmrc", wanted: true)
  end

  # The button is an admin asking for a specific source and month, and must not
  # be governed by what the schedule thinks is worth pulling. Only unattended
  # fetching is restricted.
  test "the guard does not reach the fetcher itself" do
    Rates::GapFinder.stub(:wanted?, false) do
      result = Rates::Fetcher.stub(:fetch_url, nil) do
        Rates::Fetcher.fetch_and_store("ecb_daily", Date.current)
      end
      assert_no_match(/unknown source/, result[:error].to_s)
    end
  end

end
