# frozen_string_literal: true

# Fills in rate periods the books need and the database does not have.
#
# The scheduled per-source jobs fetch the CURRENT period. This one is the safety
# net for everything else: a missed run, a server down on the 3rd, a backdated
# entry, an entity whose books start in 2018, or a currency added today whose
# history is empty.
#
# Argument-free and idempotent on purpose. There is nothing to pass and nothing
# to co-ordinate, so it can be enqueued freely — after a bulk import, after a
# backdated save, or on a schedule — and a thousand enqueues collapse into a
# couple of runs.
class FillRateGapsJob < ApplicationJob
  queue_as :default

  class FillError < StandardError; end

  retry_on FillError, wait: 1.hour, attempts: 3

  after_discard do |job, error|
    AdminMailer.with(source: "gap fill", error: error.message)
               .exchange_rates_fetch_failed.deliver_later
  end

  def perform
    return unless Rates::Fetcher.enabled?

    gaps = Rates::GapFinder.call
    return if gaps.empty?

    problems = []
    filled   = 0

    gaps.each do |source, period|
      result = Rates::PublicationWatcher.around(source) do
        Rates::Fetcher.fetch_and_store(source, period)
      end

      if result[:success]
        filled += result[:count].to_i
      elsif result[:error].present?
        # ONE line per broken source, not per period: a publisher that has moved
        # a URL fails for every month at once, and thirty identical sentences in
        # one email is how an alarm stops being read.
        problems << "#{source}: #{result[:error]}" unless problems.any? { |p| p.start_with?("#{source}:") }
      end
    end

    Rails.logger.info "FillRateGaps: #{gaps.size} gap(s), #{filled} rate(s) stored"

    # A period simply not published yet is not a failure and is not counted
    # here — see Rates::Fetcher, which reports that as :not_published.
    raise FillError, problems.join("; ") if problems.any?
  end
end
