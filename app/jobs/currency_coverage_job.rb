# frozen_string_literal: true

# An admin has added a currency. Ask every source whether it publishes one, tell
# them the answer, and fetch it so the answer becomes true.
#
# A job rather than part of the request: several HTTP requests with real
# timeouts, and a form submission has no business waiting for them.
class CurrencyCoverageJob < ApplicationJob
  queue_as :default

  # No retry_on. A failed probe is not worth chasing — the currency is added
  # either way, and the nightly sweep picks it up once the feed is back.
  def perform(code:, admin_id:, locale: nil)
    admin = Admin.find_by(id: admin_id)
    return unless admin&.email_address.present?

    coverage  = Rates::CoverageProbe.call(code)
    published = coverage.select { |_s, yes| yes }.keys
    missing   = coverage.reject { |_s, yes| yes }.keys

    AdminMailer.with(admin: admin, code: code, published: published,
                     missing: missing, locale: locale)
               .currency_coverage.deliver_now

    seed_latest_period(published)
  end

  private

  # FETCH NOW, OR NOTHING EVER FETCHES THIS CURRENCY.
  #
  # Two faults meet here, and fixing either alone leaves the other:
  #
  # · The nightly sweep fills GAPS, and a period counts as covered when it holds
  # any rate for that source. Every period already held the currencies that
  # existed before this one, so adding a currency produced no gap, no fetch, and
  # a screen reading "no source — enter rates by hand" while the email said HMRC
  # publishes it.
  # · Rates::GapFinder learns what a source publishes from its MOST RECENT
  # stored period — which, for a currency added today, predates the currency.
  # HMRC's latest period held no hryvnia, so the sweep would conclude HMRC does
  # not publish it and never ask again.
  #
  # That is the deadlock this breaks: one fetch puts the currency into that
  # latest period, and the sweep takes the history from there. Only sources the
  # probe just confirmed, so it is one request each and never asks a feed for
  # something it does not carry.
  def seed_latest_period(sources)
    sources.each do |source|
      # THE LATEST PERIOD THIS SOURCE ACTUALLY HAS, never "the current month".
      #
      # Asking every source for the current month gets nothing from the ECB,
      # whose month-end spot for August does not exist on the 21st, or the
      # Bundesbank, whose August average is computed on 3 September — silently
      # seeding no rates for exactly the two sources a euro report depends on,
      # and leaving the deadlock in place for them.
      #
      # The same rule the fetch button on screen uses, shared rather than
      # copied. Every parser stores the span the FEED declares, so a month can
      # never be filed under the wrong one.
      month = RateSourceConfig.latest_available_period(source)
      date  = RateSourceConfig.fetch_date_for(source, month)

      Rates::PublicationWatcher.around(source) do
        Rates::Fetcher.fetch_and_store(source, date)
      end
    rescue StandardError => e
      # One unreachable feed must not lose the others, and the currency is
      # added either way.
      Rails.logger.warn "CurrencyCoverageJob: #{source} seed failed: #{e.message}"
    end
  end
end
