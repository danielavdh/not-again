# frozen_string_literal: true

require "test_helper"

# 21 Oct 2026: a publisher's server reset the TLS handshake. The exception
# escaped the fetcher, aborted the whole run — every other source skipped — and
# was not the job's own retryable error, so the "failed after all retries"
# email went out after a single attempt.
class FillRateGapsJobTest < ActiveJob::TestCase
  def gaps = [ [ "ecb_daily", Date.new(2026, 10, 1) ], [ "bundesbank", Date.new(2026, 9, 1) ] ]

  test "a connection reset is a miss for that source, not the end of the run" do
    fetched = []
    fake = ->(url) {
      fetched << url
      raise Errno::ECONNRESET, "SSL_connect" if url.include?("ecb.europa.eu")
      nil
    }

    Rates::Fetcher.stub(:enabled?, true) do
      Rates::GapFinder.stub(:call, gaps) do
        Net::HTTP.stub(:start, ->(host, *_args, **_kw, &_blk) { fake.call("https://#{host}/") }) do
          assert_raises(FillRateGapsJob::FillError) { FillRateGapsJob.new.perform }
        end
      end
    end

    assert fetched.any? { |u| u.include?("bundesbank") }, "the next source is still tried"
  end

  test "the failure is the job's own error, so it is retried rather than discarded" do
    Rates::Fetcher.stub(:enabled?, true) do
      Rates::GapFinder.stub(:call, gaps.first(1)) do
        Net::HTTP.stub(:start, ->(*_a, **_k, &_b) { raise OpenSSL::SSL::SSLError, "reset" }) do
          assert_enqueued_with(job: FillRateGapsJob) do
            FillRateGapsJob.perform_now
          end
        end
      end
    end
  end
end
