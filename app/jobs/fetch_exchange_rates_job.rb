# frozen_string_literal: true

class FetchExchangeRatesJob < ApplicationJob
  queue_as :default

  class FetchError < StandardError; end

  retry_on FetchError, wait: 1.hour, attempts: 3

  after_discard do |job, error|
    source = job.arguments.first || 'all'

    # No recipient lookup and no guard: the mailer addresses every owner and
    # falls back to CONTACT_EMAIL. Guarding on a sudo admin dropped the alert
    # entirely on an installation with none — silence exactly where an alarm was
    # due.
    AdminMailer.with(
      source: source,
      error: error.message
    ).exchange_rates_fetch_failed.deliver_later
  end

  def perform(source = nil)
    return unless Rates::Fetcher.enabled?

    date = Date.current

    # A source is fetched by name, from db/exchange_rate_sources.yml. No branch
    # per feed: adding one is a YAML entry, and this job already handles it.
    result = if source.blank?
      Rates::Fetcher.fetch_and_store!(date: date)
    else
      # Nothing is fetched unattended unless something wants it — tier 1
      # displays through it, or a country's rule names it. config/recurring.yml
      # holds one entry per source, and without this a shipped source would be
      # pulled nightly by every installation for countries it has never heard
      # of. ecb_daily is the case that forces it: ~250 periods a year rather
      # than 12.
      #
      # The same rule as the gap-filler, and deliberately the same method, so a
      # schedule and a sweep can never disagree about what is wanted.
      unless Rates::GapFinder.wanted?(source)
        Rails.logger.info "ExchangeRates [#{source}]: no rule or display use — not fetched"
        return
      end

      # An ECB fetch is only meaningful once the month is over — what is stored
      # is the month-end figure, so asking mid-month would record the wrong day
      # as the month's rate. Declared in the file as `semantics: month_end_spot`
      # rather than hardcoded here.
      return if RateSourceConfig.semantics_for(source) == "month_end_spot" &&
                date != date.end_of_month

      # Wrapped so that a publisher starting to carry a new currency reaches the
      # businesses that have been entering it by hand — see
      # Rates::PublicationWatcher.
      Rates::PublicationWatcher.around(source) do
        Rates::Fetcher.fetch_and_store(source, date)
      end
    end

    problems = failures_in(result)
    raise FetchError, problems.join("; ") if problems.any?

    Rails.logger.info "ExchangeRates [#{source || 'all'}]: #{result.inspect}"
  end

  private

  # fetch_and_store! returns ONE RESULT PER SOURCE — { "ecb" => {...}, ... } —
  # so reading :success and :error on that outer hash finds nil on both. A
  # source whose URL a publisher had quietly changed then failed every night,
  # raised nothing, and emailed nobody; the first symptom would be a report
  # months later with no rate in it.
  #
  # A period that is not published yet is NOT a failure: every month-average
  # source is empty until its month ends.
  def failures_in(result)
    return [] unless result.is_a?(Hash)

    # Single-source shape.
    if result.key?(:success) || result.key?(:error)
      return result[:error].present? || result[:success] == false ? [ result[:error].to_s ] : []
    end

    # Multi-source shape: every source is checked, and every failure is named.
    result.filter_map do |source, outcome|
      next unless outcome.is_a?(Hash)
      next unless outcome[:error].present? || outcome[:success] == false

      "#{source}: #{outcome[:error]}"
    end
  end
end
