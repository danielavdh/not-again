# frozen_string_literal: true

module Rates
  # Which sources publish a given currency. Every feed lists its currencies in
  # every response, so asking them answers it — and the admin adding a currency
  # learns what they are in for before meeting it as a report that will not
  # convert.
  #
  # The honest limit: this can only ask sources the app already has. A currency
  # nobody in the registry publishes leaves two ways forward — a developer adds
  # the source, because a parser is code, or the business enters its own rates
  # by hand with evidence.
  module CoverageProbe
    # ASKED ONCE, WHEN A CURRENCY IS ADDED, AND NEVER STORED.
    #
    # A STORED RATE IS THE PROOF OF PUBLICATION. The nightly fetch stores every
    # currency the app supports that a feed returns, so the day after a currency
    # is added, what we HOLD says which sources publish it — as fact rather than
    # as a probe's opinion. Rates::PublicationWatcher already fires when a
    # source starts carrying something new, on the ordinary fetch, at no cost.
    #
    # That leaves the probe one job: telling the admin what they are in for in
    # the gap between adding a currency and the first fetch, which the 5am job
    # closes within a day. So the answer goes in the email and nowhere else — no
    # column, no cache, and NO NIGHTLY RE-CHECK of coverage.
    #
    # Four HTTP requests, so this belongs in a job and never in a request.
    def self.call(code, on: Date.current)
      code = code.to_s.upcase

      RateSourceConfig.all.index_with { |source| publishes?(source, code, on) }
    end

    # { currency => [sources] }, from what has already been STORED. No network,
    # so the index can show it — and it is the more useful answer once rates
    # have been fetched, being a fact rather than a probe.
    #
    # Absence here means "not fetched yet" as well as "not published": a
    # currency added this morning is uncovered by both.
    def self.stored_coverage
      ExchangeRate.where(entity_id: nil)
                       .distinct
                       .pluck(:from_currency, :to_currency, :source)
                       .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(from, to, source), out|
        out[from] |= [ source ]
        out[to]   |= [ source ]
      end
    end

    # A source publishes a currency if its own feed returns a rate for it.
    # Failures are false, not an exception: one unreachable feed must not stop
    # the other three answering.
    #
    # TRIES THE PREVIOUS PERIOD TOO, and it must. A monthly AVERAGE only exists
    # once its month is over, so asking about the current month on the 20th
    # finds an empty response — which reads exactly like "does not publish this
    # currency", and would send an admin off to enter rates by hand for a
    # currency the feed carries.
    def self.publishes?(source, code, on)
      return true if RateSourceConfig.base_for(source) == code

      periods = [ on, on.prev_month.end_of_month ]
      periods.any? do |date|
        rates = Rates::Fetcher.probe(source, date)
        rates.is_a?(Hash) && rates.key?(code)
      end
    rescue StandardError
      false
    end
  end
end
