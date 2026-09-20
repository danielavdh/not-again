# frozen_string_literal: true

module Rates
  # Which rate periods are missing, worked out from the SAVED REPORTS. A report
  # declares the period it covers, and a report is the only thing that ever
  # converts a currency, so there is no policy to configure and no earliest date
  # to enforce.
  #
  # This is what stops a missed scheduled run being permanent: before it, a
  # server down on the 3rd meant the Bundesbank retried three times, emailed
  # sudo, and then nothing happened until the following month.
  class GapFinder
    # [[source, period_start], ...] — the unit is (SOURCE, PERIOD), never
    # (currency, period), because every feed publishes all of its currencies in
    # one response. Three missing currency-months collapse into one fetch.
    def self.call
      @published_by = nil   # one run, one look at each source
      periods = periods_reported_on
      return [] if periods.empty?

      fillable_sources.flat_map do |source|
        periods
          .reject { |month| reaches_before_publisher?(source, month) }
          .reject { |month| covered?(source, month) }
          .map    { |month| [ source, month ] }
      end
    end

    # Every source whose history can actually be fetched — see
    # RateSourceConfig.backfillable?. In practice that is all of them but ESTV,
    # which serves the current month and ignores every date parameter, so asking
    # it for history would fail every night forever.
    #
    # Whether the feed can serve the past is the only question being asked. A
    # source's ROLE is not a safe proxy: judging by "sources a report would
    # read" also caught the Bundesbank, which is month-parameterised and
    # perfectly backfillable, so choosing EUR (BMF) on an older report asked for
    # rates that were never fetched.
    def self.fillable_sources
      RateSourceConfig.all.select { |s| RateSourceConfig.backfillable?(s) && wanted?(s) }
    end

    # FETCH WHAT IS NEEDED, NOT WHAT IS DECLARED.
    #
    # A source in exchange_rate_sources.yml is one the app CAN read. It becomes
    # one the app SHOULD pull when something actually wants it: tier 1 displays
    # through it (a display default, or the cross-rate fallback — true whatever
    # countries exist, including none), or some country's rule names it.
    #
    # Without this, shipping a source means every installation fetches it
    # nightly for ever, for countries it has never heard of. It matters most for
    # a DAILY source: ~250 periods a year against 12, and ecb_daily exists for
    # the Netherlands and Spain, neither of which every installation files in.
    #
    # The manual fetch button is NOT governed by this — an admin asking for a
    # specific source and month gets it. This decides only what happens
    # unattended.
    #
    # Not memoised on purpose: both config readers memoise their own files, so
    # this is array work, and a memo here would be read by FetchExchangeRatesJob
    # in a long-lived worker and go stale the moment a rule changed.
    def self.wanted?(source)
      (RateSourceConfig.display_source_keys +
       RateRuleConfig.all_accepted_sources).include?(source.to_s)
    end

    # The months SAVED REPORTS cover — not the months that have postings.
    #
    # Asking the postings is wrong twice over. Conversion only ever happens at
    # report time: a journal entry is single-currency by construction, fixed by
    # its balance account, so bookkeeping never converts anything. And nominal
    # accounts carry no currency at all, so COALESCE(posting.currency,
    # account.currency) returns nil for exactly the postings a report sums.
    #
    # `reports` stores start_date and end_date, and filing creates a report over
    # the obligation's period, so one source covers reports and tax submissions
    # both.
    #
    # Everything else is ad-hoc — a trial balance over any dates the user picks
    # — which is unpredictable by nature and belongs on the on-demand path
    # rather than being guessed at here.
    def self.periods_reported_on
      return [] unless multi_currency_books?

      cutoff = Date.current.end_of_month

      Report.pluck(:start_date, :end_date).flat_map { |from, to|
        months_between(from, [ to, cutoff ].min)
      }.uniq.sort
    end

    # Reports run into the future. Fetching a month that has not happened
    # returns "not published yet", which is harmless but noise in the logs every
    # night, so this is capped at the current month.
    def self.months_between(from, to)
      return [] if from.blank? || to.blank? || to < from

      month = from.beginning_of_month
      months = []
      while month <= to
        months << month
        month = month.next_month
      end
      months
    end

    # More than one currency anywhere in the posted books. A posting with no
    # currency of its own takes its account's.
    def self.multi_currency_books?
      Posting
        .joins(:journal_entry).joins(:account)
        .where(journal_entries: { posted: true })
        .distinct
        .count(Arel.sql("COALESCE(postings.currency, accounts.currency)")) > 1
    end

    # COVERED MEANS EVERY CURRENCY THIS SOURCE DEMONSTRABLY PUBLISHES, not "some
    # rate exists". Meaning the latter made ADDING A CURRENCY FETCH NOTHING,
    # EVER: every period already held the currencies that existed before it, so
    # every period looked covered and the sweep found no gaps.
    #
    # "Demonstrably publishes" is what stops this crying wolf. The ECB will
    # never carry hryvnia, and asking it nightly for a currency it does not have
    # would be exactly the permanent false alarm the `earliest` rule exists to
    # avoid. So the test is not "which currencies do we support" but "which did
    # THIS SOURCE actually deliver in its most recent period" — a fact it told
    # us itself, needing no configuration and going stale on its own the day a
    # publisher drops a currency.
    #
    # A DAILY SOURCE CANNOT BE ASKED "is this day covered". No publisher quotes
    # on a Saturday, so asking per day would report every weekend and public
    # holiday as a gap, for ever, and nothing would ever fill them. A daily
    # source is judged by the MONTH, which is also its fetch unit: one request
    # stores that month's published days, all of them, so a past month holding
    # any day at all was fetched whole.
    #
    # The current month is never covered, deliberately — it is still accruing
    # days, and re-fetching it is one cheap request.
    def self.covered?(source, month)
      stored =
        if RateSourceConfig.daily?(source)
          return false if month >= Date.current.beginning_of_month
          currencies_in_month(source, month)
        else
          currencies_stored(source, month)
        end
      return false if stored.empty?

      (published_by(source) - stored).empty?
    end

    # The span COVERING a date — one row per pair for a monthly source.
    def self.currencies_stored(source, month)
      ExchangeRate.where(source: source, entity_id: nil).covering(month)
                       .pluck(:from_currency, :to_currency).flatten.uniq.to_set
    end

    # Every row STARTING inside the month — many per pair for a daily source,
    # which is why it cannot use `covering`, whose one date would answer only
    # for that one day.
    def self.currencies_in_month(source, month)
      ExchangeRate.where(source: source, entity_id: nil)
                       .where(valid_from: month.beginning_of_month..month.end_of_month)
                       .pluck(:from_currency, :to_currency).flatten.uniq.to_set
    end

    # What the source delivered most recently — its own statement of what it
    # carries. Memoised per run: the sweep asks once per source, not once per
    # period.
    #
    # A currency added TODAY is not in here, because the latest period was
    # fetched before it existed. That is why CurrencyCoverageJob fetches the
    # current period the moment a currency is added: without it this method can
    # never learn, and the two would deadlock.
    def self.published_by(source)
      @published_by ||= {}
      @published_by[source] ||= begin
        latest = ExchangeRate.where(source: source, entity_id: nil).maximum(:valid_from)
        latest ? currencies_stored(source, latest) : Set.new
      end
    end

    # No archive reaches before its publisher did. Without this a posting dated
    # 1995 would have the job asking the ECB for 1995 every night, indefinitely
    # — and an alarm that cries wolf is worse than none.
    #
    # Unset means "try": one wasted fetch costs less than wrongly refusing a
    # period the publisher actually has.
    def self.reaches_before_publisher?(source, month)
      earliest = RateSourceConfig.fetch_config(source)&.dig("earliest")
      earliest.present? && month < earliest.to_date
    end
  end
end
