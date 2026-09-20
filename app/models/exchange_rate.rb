# frozen_string_literal: true

class ExchangeRate < ApplicationRecord

  # Methods rather than constants: a constant is frozen at boot and would not
  # notice RateSourceConfig.reload!. Both read db/exchange_rate_sources.yml, so
  # adding a source is a YAML edit and nothing else.
  def self.cross_rate_base
    RateSourceConfig.bases
  end

  # Which published series a DISPLAY currency reads its rates from: prefer the
  # source whose base currency IS the display currency, and cross-rate from the
  # fallback otherwise. HMRC publishes against GBP, the ECB against EUR, so a
  # sterling report reads HMRC and everything else reads the ECB.
  #
  # A lookup table rather than reversing the base currencies: the BMF will also
  # publish against EUR, so a base currency does not identify a source on its
  # own.

  # Raised when no rate can be found for a conversion that needs one — never a
  # silent fallback to 1.0, nor returning the amount unconverted, which is 1.0
  # wearing a different hat. A hryvnia figure passed through at 1:1 is out by a
  # factor of forty and looks entirely normal on the page.
  #
  # Carries the parts, so a caller can say something actionable: "No ECB rate
  # for GBP in July 2018" rather than "something went wrong".
  class RateUnavailable < StandardError
    attr_reader :from_currency, :to_currency, :date, :source

    def initialize(from_currency:, to_currency:, date:, source:)
      @from_currency = from_currency
      @to_currency   = to_currency
      @date          = date
      @source        = source
      super("No #{source} rate for #{from_currency} to #{to_currency} on #{date}")
    end
  end

  # NULL means it was FETCHED — nobody entered it, a publisher did. Nullified
  # rather than cascaded when an admin is offboarded: other people's reports
  # depend on rates that outlive whoever entered them.
  belongs_to :entered_by, class_name: "Admin", optional: true

  # A rate belonging to ONE business rather than to the world: a Swiss group's
  # internal rate, a chosen bank, a documented Tageskurs for a currency nobody
  # publishes. NULL means it is a public fact.
  belongs_to :entity, class_name: "Entity", optional: true

  # The period these figures are VALID for, which is not the same as any single
  # date they were stored under. ECB rows carry a month-END effective_date, so
  # July's rate would otherwise display as "31 July 2026" — reading like a rate
  # for one day rather than the figure that governs the whole month.
  def period_label
    return I18n.l(valid_from, format: :short_date) if valid_from == valid_to

    if valid_from == valid_from.beginning_of_month && valid_to == valid_from.end_of_month
      "#{I18n.t('date.month_names')[valid_from.month]} #{valid_from.year}"
    else
      "#{I18n.l(valid_from, format: :short_date)} – #{I18n.l(valid_to, format: :short_date)}"
    end
  end

  # Tier 1's PREFERRED series for a currency — the head of the very list the
  # dropdown offers, so the menu and the column can never name different things.
  # Whether it is the series actually used depends on whether it reaches the
  # report's whole period: see .source_for_span.
  def self.source_for(display_currency)
    RateSourceConfig.sources_for_display(display_currency).first
  end

  def derive_span_from_effective_date
    self.valid_from ||= effective_date&.beginning_of_month
    self.valid_to   ||= valid_from&.end_of_month

    # The form asks for a SPAN and effective_date is still NOT NULL, so
    # whichever a caller supplies, the other follows. Needed only until the
    # migration drops the column.
    self.effective_date ||= valid_from
  end
  private :derive_span_from_effective_date

  # Every source is monthly today, so the month containing effective_date IS the
  # span. Set both explicitly and this does nothing: a daily source says
  # valid_from == valid_to and must not be second-guessed.
  before_validation :derive_span_from_effective_date

  validates :from_currency, presence: true, length: { is: 3 }
  validates :to_currency, presence: true, length: { is: 3 }
  validates :rate, presence: true, numericality: { greater_than: 0 }

  # "1 EUR = 17.0 IDR" — echoed back after saving, because a rate is the one
  # figure here nothing else can check. A publisher covers few pairs, so a typed
  # rate usually has nothing to be compared against; and both of its ways of
  # going wrong are silent. Written the German way, "17.000" casts to 17 and
  # passes every validation; entered the wrong way round, 1.25 instead of 0.80,
  # it is a perfectly ordinary number. Saying it as a sentence puts the
  # magnitude and the direction where they can be read.
  #
  # The separator is a point, matching the field: a rate is not money and does
  # not follow the admin's number format.
  def rate_sentence
    return nil if rate.blank? || from_currency.blank? || to_currency.blank?
    "1 #{from_currency} = #{rate.to_s('F').sub(/(\.\d*[1-9])0+\z|\.0+\z/, '\1')} #{to_currency}"
  end
  validates :effective_date, presence: true
  # Mirrors idx_exchange_rates_unique. Scoped to the SOURCE and the OWNER as
  # well as the pair and the span, because a rate is only a duplicate of another
  # rate from the same publisher for the same taxpayer: two sources may publish
  # the same pair for the same month and disagree — the ECB and the Bundesbank
  # both quote against EUR — and a taxpayer's OWN rate legitimately sits
  # alongside the public one.
  #
  # Non-overlap of spans is enforced in the database
  # (exchange_rates_no_overlap); it cannot be expressed as a validation.
  validates :from_currency,
            uniqueness: { scope: %i[to_currency valid_from source entity_id] }

  scope :for_pair, ->(from, to) { where(from_currency: from, to_currency: to) }
  # No per-source scopes: one per source would need a fourth and a fifth now,
  # and would be the exact hardcoding the registry exists to remove. Use
  # where(source:) with a name from RateSourceConfig.

  scope :for_month, ->(date) {
    month_start = date.beginning_of_month
    month_end = date.end_of_month
    where(effective_date: month_start..month_end)
  }

  # The row whose validity span contains this date. THE lookup — it serves a
  # daily rate (a one-day span), a monthly rate, and ESTV's average over the
  # 25th-to-24th, without knowing which it is looking at. The database
  # guarantees at most one match per (pair, source, owner), via the
  # exchange_rates_no_overlap exclusion constraint.
  scope :covering, ->(date) {
    where("valid_from <= :d AND valid_to >= :d", d: date)
  }

  # `entity:` is whose books these figures are. Pass it wherever it is known —
  # without it a business's own elected rates are simply not consulted, which is
  # correct for a consolidated view built from no single entity, and wrong for
  # that entity's own report.
  #
  # `scheme:` turns this from an ordinary REPORT into a TAX REPORT, and is the
  # only thing that changes which sources are consulted. Without it, tier 1
  # decides: prefer the source whose base currency is the display currency,
  # otherwise cross-rate — right for anything on screen, which is management
  # information bound by no authority. With it, the scheme's country decides,
  # from db/exchange_rate_rules.yml, and may name several sources in preference
  # order: a German VAT return wants the Bundesbank monthly average that §16(6)
  # UStG names, while a German profit and loss wants the ECB. A country with no
  # rule falls back to tier 1 rather than to nothing.
  #
  # `sources:` is an explicit override — the user chose a series in the report's
  # converted-column dropdown, and their choice outranks both tier 1 and the
  # country's rule. A tax REPORT is not offered the choice, which is where the
  # authority's rule stays binding.
  #
  # Not the same as a SUBMISSION (app/services/filing/), the separate and
  # optional act of transmitting one through a connector; most countries here
  # have no connector and stop at the tax report.
  def self.translator(to_currency, date:, entity: nil, scheme: nil, sources: nil)
    Translator.new(to_currency, date, entity,
                   sources: sources.presence || sources_for_scheme(scheme),
                   date_basis: date_basis_for_scheme(scheme))
  end

  def self.sources_for_scheme(scheme)
    return nil if scheme.blank?

    country = TaxSchemeConfig.country_for(scheme)
    RateRuleConfig.accepted_sources(country, scheme: scheme).presence
  end

  # Only a TAX REPORT is bound to a date basis, for the same reason it is bound
  # to a source: an ordinary report is management information, and reading it at
  # the rate of the day is what anyone would expect. A tax figure follows the
  # country's law about WHICH day.
  def self.date_basis_for_scheme(scheme)
    return RateRuleConfig::TRANSACTION_DATE if scheme.blank?

    country = TaxSchemeConfig.country_for(scheme)
    RateRuleConfig.date_basis_for(country, scheme: scheme)
  end

  # Does this source hold a rate for EVERY month the report spans, for every
  # currency it must convert?
  #
  # All or nothing, because a converted column is only comparable with itself:
  # three months at ESTV and one at the ECB is a total nobody can defend, and a
  # reader cannot see the seam. One grouped query rather than a lookup per month
  # — a year of a three-currency business is 36 questions, and this runs on
  # every report.
  def self.covers_span?(to_currency:, from_currencies:, source:, from:, to:)
    wanted = Array(from_currencies).map(&:to_s).uniq - [ to_currency.to_s ]
    return true if wanted.empty? || source.blank?

    months = (from.beginning_of_month..to.beginning_of_month).count { |d| d.day == 1 }

    # BOTH DIRECTIONS, because that is what the translator does. HMRC publishes
    # "currency units per £1" and stores GBP→EUR, so a sterling report
    # converting euros reads that row inverted. Counting only one direction
    # found no HMRC row at all, so every sterling report decided HMRC could not
    # reach its period and quietly fell back to the euro cross-rate.
    display = to_currency.to_s
    other   = Arel.sql("(CASE WHEN from_currency = #{connection.quote(display)} " \
                       "THEN to_currency ELSE from_currency END, date_trunc('month', valid_from))")

    held = where(source: source)
             .where("(from_currency = :d AND to_currency IN (:w)) OR " \
                    "(to_currency = :d AND from_currency IN (:w))", d: display, w: wanted)
             .where(valid_from: ..to.end_of_month, valid_to: from.beginning_of_month..)
             .distinct
             .count(other)

    held >= months * wanted.size
  end

  # Which series a REPORT reads, decided once for the whole period. Tier 1
  # prefers the series published in the display currency — francs at ESTV,
  # sterling at HMRC — and where that cannot reach every month the report cross-
  # rates instead, for all of it, and says so: the caller shows "CHF via ECB"
  # rather than quietly mixing two.
  #
  # Nothing here is about tax. A tax report is bound by its country's rule and
  # never comes through this method — see .sources_for_scheme.
  def self.source_for_span(to_currency, from_currencies:, from:, to:, preferred: nil)
    preferred = preferred.presence || RateSourceConfig.sources_for_display(to_currency).first
    return preferred if preferred.blank?
    return preferred if covers_span?(to_currency: to_currency, from_currencies: from_currencies,
                                     source: preferred, from: from, to: to)

    RateSourceConfig.display_fallback || preferred
  end

  # Find rate for the month, with fallback to previous month if not found
  def self.rate_for(from_currency, to_currency, date: Date.current, source: nil)
    return 1.0 if from_currency == to_currency

    # The span covering this date.
    rate = find_rate_on(from_currency, to_currency, date, source)
    return rate if rate

    # One period back — this month's rate may not be published yet. Deliberately
    # one step, not "the most recent span before this date": unbounded lookback
    # would silently reach for a rate six months old rather than admitting it
    # has none.
    rate = find_rate_on(from_currency, to_currency, (date - 1.month).end_of_month, source)
    return rate if rate

    # Try cross-rate via base currency (EUR for ECB, GBP for HMRC)
    cross_rate_for(from_currency, to_currency, date, source)
  end

  # The published rate for this pair on this date, or its inverse — feeds
  # publish one direction only (the ECB gives EUR→USD, never USD→EUR). The order
  # is belt and braces: the exclusion constraint already guarantees at most one
  # covering span per source and owner.
  def self.find_rate_on(from_currency, to_currency, date, source)
    scope = for_pair(from_currency, to_currency).covering(date)
    scope = scope.where(source: source) if source

    scope.order(valid_from: :desc).limit(1).pluck(:rate).first ||
      inverse_rate(from_currency, to_currency, date, source)
  end

  def self.inverse_rate(from_currency, to_currency, date, source = nil)
    scope = for_pair(to_currency, from_currency).covering(date)
    scope = scope.where(source: source) if source

    inverse = scope.order(valid_from: :desc).limit(1).pluck(:rate).first
    inverse ? (1.0 / inverse) : nil
  end

  def self.cross_rate_for(from_currency, to_currency, date, source)
    return nil unless source

    base = cross_rate_base[source]
    return nil unless base
    return nil if from_currency == base || to_currency == base

    # Get from_currency -> base and base -> to_currency
    rate_to_base = find_rate_on(from_currency, base, date, source) ||
                   find_rate_on(from_currency, base, (date - 1.month).end_of_month, source)
    return nil unless rate_to_base

    rate_from_base = find_rate_on(base, to_currency, date, source) ||
                     find_rate_on(base, to_currency, (date - 1.month).end_of_month, source)
    return nil unless rate_from_base

    rate_to_base * rate_from_base
  end

  def self.convert(amount, from_currency, to_currency, date)
    rate = rate_for(from_currency, to_currency, date: date)
    rate ? (amount * rate).round : nil
  end

  def self.translate(amount_cents, from_currency, to_currency, date:)
    return amount_cents if from_currency == to_currency
    return 0 if amount_cents.nil? || amount_cents == 0

    source = source_for(to_currency)
    rate = rate_for(from_currency, to_currency, date: date, source: source)
    raise RateUnavailable.new(from_currency: from_currency, to_currency: to_currency,
                              date: date, source: source) unless rate

    (amount_cents * rate).round
  end

  # The gap left over when the two legs of a CROSS-CURRENCY TRANSFER are each
  # converted into the display currency and no longer cancel.
  #
  # Only transfers, and deliberately: they are the one entry shape holding two
  # currencies, so the pair of amounts was fixed by a real rate at the moment
  # the money moved. Everything else in these books is single-currency by
  # construction and converts only when a report is written, so nothing else can
  # produce a variance at all.
  #
  # A modest figure is ordinary — spread, plus the distance between the day's
  # rate and a monthly average. A large one means the exchange was done well off
  # the authority's rate, or a wrong amount was typed on one leg of a transfer.
  #
  # `source:` is the series the report is actually reading, passed in rather
  # than re-derived: a report whose preferred series could not cover its period
  # falls back for its figures, and a variance computed at the preferred series
  # would be measuring a different report from the one on the screen.
  def self.calculate_fx_variance(from_date:, to_date:, display_currency:, admin:, entity_codes: nil, source: nil)
    fx_variance_rows(
      from_date: from_date, to_date: to_date, display_currency: display_currency,
      admin: admin, entity_codes: entity_codes, source: source
    ).sum { |row| row[:variance_cents] }
  end

  # The same figure, itemised: one row per cross-currency transfer, carrying the
  # rate its two amounts imply, the published rate its legs were translated at,
  # and the cents it contributed. The sum of :variance_cents is exactly
  # #calculate_fx_variance, so the FX-variance page and the reports' single line
  # can never disagree.
  def self.fx_variance_rows(from_date:, to_date:, display_currency:, admin:, entity_codes: nil, source: nil)
    return [] unless display_currency

    from_date, to_date = fx_variance_span(from_date, to_date, admin)
    je_ids = cross_currency_transfer_je_ids(admin, from_date, to_date, entity_codes)
    return [] if je_ids.empty?

    source ||= source_for(display_currency)
    rates_cache = {}

    # Load only the small set of relevant postings — pluck, no AR objects
    by_je = admin.accessible_postings
      .where(journal_entry_id: je_ids)
      .joins(:journal_entry)
      .pluck(
        :journal_entry_id,
        :entry_type,
        :amount,
        :currency,
        :account_id,
        Arel.sql('journal_entries.entry_date'),
        Arel.sql('journal_entries.memo')
      )
      .group_by(&:first)

    by_je.filter_map do |je_id, legs|
      next unless legs.size == 2

      entry_date = legs.first[5]
      month      = entry_date.beginning_of_month

      debit_leg  = legs.find { |l| l[1] == "debit" }
      credit_leg = legs.find { |l| l[1] == "credit" }
      next unless debit_leg && credit_leg

      to_amount,   to_currency,   to_account_id   = debit_leg[2],  debit_leg[3],  debit_leg[4]   # money in
      from_amount, from_currency, from_account_id = credit_leg[2], credit_leg[3], credit_leg[4]  # money out

      # RAISE on a missing rate, never skip. A leg that could not be converted
      # once scored zero, so the variance became the whole of the other leg — a
      # €10,000 transfer with one month's rate missing reported about £9,000.
      # ReportsController#with_rates catches this and names the missing rate.
      translated_in  = fx_translate_leg(to_amount,   to_currency,   display_currency, month, source, rates_cache)
      translated_out = fx_translate_leg(from_amount, from_currency, display_currency, month, source, rates_cache)

      {
        journal_entry_id:  je_id,
        entry_date:        entry_date,
        memo:              legs.first[6],
        from_currency:     from_currency,
        from_amount_cents: from_amount,
        from_account_id:   from_account_id,
        to_currency:       to_currency,
        to_amount_cents:   to_amount,
        to_account_id:     to_account_id,
        implied_rate:      from_amount.zero? ? nil : to_amount.fdiv(from_amount),
        published_rate:    fx_pair_rate(from_currency, to_currency, month, source, rates_cache),
        variance_cents:    translated_in - translated_out
      }
    end
  end

  # nil from_date means "since the books began" — the FX-variance page and the
  # balance sheet are both cumulative. nil to_date means today.
  def self.fx_variance_span(from_date, to_date, admin)
    if from_date.nil?
      earliest  = admin.accessible_journal_entries.where(posted: true).minimum(:entry_date)
      from_date = earliest || Date.current.beginning_of_year
    end
    [ from_date, to_date || Date.current ]
  end
  private_class_method :fx_variance_span

  # Cross-currency transfer journal entries in range, SQL only: exactly two
  # postings, two currencies, two balance-sheet accounts.
  def self.cross_currency_transfer_je_ids(admin, from_date, to_date, entity_codes)
    admin.accessible_journal_entries
      .where(entry_date: from_date..to_date, posted: true)
      .joins(postings: :account)
      .where(accounts: { account_type: [:asset, :liability, :equity] })
      .then { |s| entity_codes.present? ? s.where("SUBSTRING(accounts.code, 2, 2) IN (?)", entity_codes) : s }
      .group('journal_entries.id')
      .having('COUNT(DISTINCT postings.id) = 2')
      .having('COUNT(DISTINCT postings.currency) = 2')
      .having('COUNT(DISTINCT accounts.id) = 2')
      .pluck('journal_entries.id')
  end
  private_class_method :cross_currency_transfer_je_ids

  # One transfer leg translated into the display currency at its month's rate.
  def self.fx_translate_leg(amount_cents, currency, display_currency, month, source, cache)
    return amount_cents if currency == display_currency

    rate = (cache[[ currency, display_currency, month ]] ||=
              rate_for(currency, display_currency, date: month, source: source))
    raise RateUnavailable.new(from_currency: currency, to_currency: display_currency,
                              date: month, source: source) if rate.nil?
    (amount_cents * rate).round
  end
  private_class_method :fx_translate_leg

  # The published rate between the two transfer currencies, for display next to
  # the rate the amounts imply. Informational — nil just shows a dash.
  def self.fx_pair_rate(from_currency, to_currency, month, source, cache)
    return 1.0 if from_currency == to_currency
    cache[[ from_currency, to_currency, month ]] ||=
      rate_for(from_currency, to_currency, date: month, source: source)
  end
  private_class_method :fx_pair_rate
  
  
  class Translator
    attr_reader :to_currency, :date, :month_start, :month_end, :source

    # `entity` is whose books are being translated, and it decides whether that
    # business's OWN rates apply; nil means the published series only. A
    # business may elect its own rate where the law allows — Switzerland permits
    # a group's internal rate, Hungary lets you pick a credit institution,
    # Germany accepts a documented daily rate for a currency nobody publishes.
    # Those rates belong to one entity and must never leak into another's
    # figures.
    #
    # `sources:` is an ORDERED preference list: the first one holding a rate
    # that covers the date wins, and the rest are the fallback. Omitted, it is
    # tier 1's single base-matching answer, which is every ordinary report.
    #
    # Only a TAX REPORT passes a list, from RateRuleConfig, and it is a list of
    # what the law actually ACCEPTS, not one built for history depth. A
    # country's law may genuinely accept only one source — Switzerland does,
    # [estv] — and a period nothing on the list can reach is an ERROR
    # (RateUnavailable), never a silent read from some other, unaccepted source
    # that happens to hold a rate. Do not add a source here to avoid a raise:
    # Art. 45 MWSTV does not accept the ECB rate at all, so an engineering
    # fallback in this field would be written into a statement of tax law.
    #
    # `date_basis:` is which DAY the rate is keyed to
    # (RateRuleConfig::DATE_BASES). It changes nothing while every source is
    # monthly, because one span then covers every day. It starts to matter the
    # moment a DAILY feed is added, which is what a national central bank
    # usually publishes: there is no rate on a Saturday, and
    # preceding_publication is the law's answer to that, not a convenience.
    def initialize(to_currency, date, entity = nil, sources: nil,
                   date_basis: RateRuleConfig::TRANSACTION_DATE)
      @to_currency = to_currency
      @date = date
      @date_basis = date_basis
      @month_start = date.beginning_of_month
      @month_end = date.end_of_month
      # How far back a lookup may reach for the last publication before a date.
      # A posting on 1 January must be able to find 31 December's rate, so the
      # window cannot stop at the month boundary. One month back covers every
      # public-holiday run there is; more would be reaching for stale rates,
      # which is the behaviour RateUnavailable exists to prevent.
      @window_start = preceding_publication? ? @month_start - 1.month : @month_start
      @sources = Array(sources).presence || [ ExchangeRate.source_for(to_currency) ]
      # The preferred source. Still what an unresolvable rate is reported
      # against, and what the single-source paths below ask for.
      @source = @sources.first
      @entity = entity
      @rates = {}
    end

    # Which source actually answered for this currency on this date — the
    # preferred one, or whatever the fallback reached; nil when no span covered
    # it and the answer came from the previous period or a cross-rate.
    #
    # This is what makes the fallback visible rather than silent: a report can
    # say CHF (estv) for August and CHF (ecb) for March, which is the difference
    # between a documented conversion and an unexplained one.
    def source_used_for(currency, on: nil, entity_id: nil)
      return nil if currency == @to_currency

      date = on || @date
      owner = entity_id || @entity&.id
      span_for(currency, owner, date)&.fetch(3)
    end

    # Every source that answered across this translator's month, in preference
    # order. One entry is the ordinary case; two means a fallback was used.
    def sources_used(currencies)
      currencies.filter_map { |c| source_used_for(c) }
                .uniq
                .sort_by { |s| @sources.index(s) || 99 }
    end

    # `on:` is the date the figure belongs to, which need not be the date this
    # translator was built for. A translator covers a MONTH's worth of rates in
    # one query: with a monthly source there is one span across that month and
    # every day gets the same answer; with a DAILY source there are many, and
    # each day gets its own. So callers can group postings by day without paying
    # a query per day.
    #
    # Daily precision is not decoration: German VAT for a currency the BMF does
    # not publish requires the Tageskurs, the rate on the day.
    #
    # `entity_id:` is whose figures these are — a CONSOLIDATED report covers
    # several entities at once, and each one's own elected rate must apply to
    # its own accounts. An account's entity is digits 2-3 of its code, so the
    # caller always knows. Defaults to the entity this translator was built for.
    def rate(from_currency, on: nil, entity_id: nil)
      return 1.0 if from_currency == @to_currency

      date = on || @date
      owner = entity_id || @entity&.id
      found = span_for(from_currency, owner, date)
      return found[2] if found

      # No span covers that day, so fall back to the cross-rate path, which
      # resolves through the source's base currency and carries no span of its
      # own.
      #
      # Resolved for the REQUESTED day, not for @date. Every caller builds one
      # translator per MONTH, keyed to the 1st, so asking for @date is invisible
      # while every source is monthly — a monthly span covers all 31 days and
      # this line is never reached. Give it a DAILY source and any day the feed
      # did not publish silently takes the 1st of the month's rate, including
      # days BEFORE the 1st resolved anything: a rate reaching forward in time
      # to a transaction it cannot have applied to. Romania's BNR publishes
      # daily and skips every weekend, so that is roughly 104 days a year.
      #
      # Memoised per (currency, day) rather than per currency for the same
      # reason.
      @rates.fetch([ from_currency, date ]) do
        @rates[[ from_currency, date ]] = ExchangeRate.rate_for(
          from_currency, @to_currency, date: date, source: @source
        )
      end || raise(RateUnavailable.new(
        from_currency: from_currency, to_currency: @to_currency,
        date: date, source: @source
      ))
    end

    def translate(amount_cents, from_currency, on: nil, entity_id: nil)
      return amount_cents if from_currency == @to_currency
      return 0 if amount_cents.nil? || amount_cents == 0

      (amount_cents * rate(from_currency, on: on, entity_id: entity_id)).round
    end

    # THE span that answers for this currency on this day, or nil. The ordinary
    # answer is the span covering the date; where the country's law keys to the
    # last publication BEFORE the transaction and nothing covers the day, this
    # falls back to the most recent span that ended before it.
    #
    # Two things it deliberately does NOT do:
    #
    # · reach forward. A rate published after the transaction cannot be the rate
    # that applied to it, whatever the gap.
    # · fall back on transaction_date. A missing rate there is a missing rate,
    # and RateUnavailable says so. Only a country that has DECLARED the
    # preceding-publication rule gets the reach, and it gets it because that
    # rule is the law, not because it is convenient.
    #
    # Spans are already ordered preferred-source-first then newest-first, so the
    # first match on either pass is the right one.
    def span_for(currency, owner, date)
      spans = spans_for(currency, owner)
      covering = spans.find { |from, to, _r, _src| date >= from && date <= to }
      return covering if covering || !preceding_publication?

      spans.select { |_from, to, _r, _src| to < date }.max_by { |_f, to, _r, _s| to }
    end

    def preceding_publication?
      @date_basis == RateRuleConfig::PRECEDING_PUBLICATION
    end

    # [[valid_from, valid_to, rate], ...] for one currency and one owner, newest
    # span first, so #rate picks the one covering a given day. The entity's OWN
    # spans come first, so an owned rate wins wherever it applies — including
    # inside a consolidated report where another entity has none, so one column
    # can mix an owned rate and a published one. That follows from electing your
    # own rate.
    #
    # Both sides are loaded ONCE PER CURRENCY, not once per entity: a twelve-
    # month report over three entities and three currencies would otherwise be
    # ~108 tiny queries. Owned rows are fetched for every entity together and
    # partitioned in memory, so a family costs what a single entity does, and a
    # family with no typed rates pays one EXISTS check for the whole month.
    def spans_for(currency, entity_id = nil)
      @published ||= {}
      published = (@published[currency] ||= published_spans(currency))
      return published unless entity_id && any_owned_rates?

      owned_by_entity(currency)[entity_id].to_a + published
    end

    # currency => { entity_id => [[valid_from, valid_to, rate], ...] }
    def owned_by_entity(currency)
      @owned ||= {}
      @owned[currency] ||= load_owned_by_entity(currency)
    end

    def load_owned_by_entity(currency)
      window = ExchangeRate.where.not(entity_id: nil)
                           .where(valid_to: @window_start.., valid_from: ..@month_end)

      direct = window.where(from_currency: currency, to_currency: @to_currency)
                     .pluck(:entity_id, :valid_from, :valid_to, :rate, :source)
                     .map { |e, f, t, r, s| [ e, f, t, r.to_f, s ] }

      # Feeds and people alike record one direction only.
      inverse = window.where(from_currency: @to_currency, to_currency: currency)
                      .pluck(:entity_id, :valid_from, :valid_to, :rate, :source)
                      .filter_map { |e, f, t, r, s| [ e, f, t, 1.0 / r.to_f, s ] if r.to_f.positive? }

      (direct + inverse).group_by(&:first).transform_values do |rows|
        rows.map { |(_e, from, to, rate, source)| [ from, to, rate, source ] }
            .sort_by(&:first).reverse
      end
    end

    # One cheap question, asked once per translator: does ANY entity hold its
    # own rate covering this month? Almost always no, and then no per-entity
    # query is ever made.
    def any_owned_rates?
      return @any_owned unless @any_owned.nil?

      @any_owned = ExchangeRate.where.not(entity_id: nil)
                               .where(valid_to: @window_start.., valid_from: ..@month_end)
                               .exists?
    end

    # `entity_id: nil` matters: without it one business's own rate would be
    # picked up as if it were a public fact and applied to everyone else's books
    # — the exact leak entity ownership exists to prevent.
    #
    # ALL accepted sources in ONE query, then ordered in Ruby by preference. The
    # sort is what implements the fallback: every span from the preferred source
    # first (newest first), then the next source, and so on. #rate takes the
    # first span COVERING the date, so the preferred source wins wherever it
    # reaches and the fallback answers only where it does not.
    #
    # Owned rates are NOT filtered by source: a hand-entered rate is source:
    # manual while a euro report reads ecb, so filtering would mean it was never
    # found.
    def published_spans(currency)
      scope = ExchangeRate.where(source: @sources, entity_id: nil)
      spans_between(scope, currency).sort_by { |from, _to, _r, source|
        [ @sources.index(source) || @sources.size, -from.to_time.to_i ]
      }
    end

    def spans_between(scope, currency)
      window = scope.where(valid_to: @window_start.., valid_from: ..@month_end)

      direct = window.where(from_currency: currency, to_currency: @to_currency)
                     .pluck(:valid_from, :valid_to, :rate, :source)
                     .map { |f, t, r, s| [ f, t, r.to_f, s ] }

      # Feeds publish one direction only — the ECB quotes EUR->USD, never
      # USD->EUR.
      inverse = window.where(from_currency: @to_currency, to_currency: currency)
                      .pluck(:valid_from, :valid_to, :rate, :source)
                      .filter_map { |f, t, r, s| [ f, t, 1.0 / r.to_f, s ] if r.to_f.positive? }

      (direct + inverse).sort_by { |f, _t, _r, _s| f }.reverse
    end

    def preload_rates(currencies)
      currencies_to_load = currencies.reject { |c| c == @to_currency || @rates.key?(c) }
      return self if currencies_to_load.empty?

      # Try current month first
      loaded = load_rates_covering(@date, currencies_to_load)

      # For any missing, try previous month (fallback)
      missing = currencies_to_load - loaded.keys
      if missing.any?
        prev_month = (@date - 1.month).end_of_month
        prev_loaded = load_rates_covering(prev_month, missing)
        loaded.merge!(prev_loaded)
      end

      # For still missing, try cross-rates
      still_missing = currencies_to_load - loaded.keys
      if still_missing.any?
        cross_loaded = load_cross_rates(still_missing)
        loaded.merge!(cross_loaded)
      end

      # nil, NOT 1.0. A currency we could not find a rate for is unknown, and
      # #rate raises on it. Caching the miss still matters — it stops every
      # figure in a report re-querying the same absent rate.
      currencies_to_load.each { |curr| @rates[curr] = loaded[curr] }
      self
    end

    private

    # Bulk preload — every rate this translator could need, in one query. Span
    # containment rather than a calendar-month window, so a daily source loads
    # exactly as well as a monthly one.
    def load_rates_covering(date, currencies)
      rates_data = ExchangeRate
        .covering(date)
        .where(source: @source)
        .where(
          "(from_currency IN (?) AND to_currency = ?) OR (from_currency = ? AND to_currency IN (?))",
          currencies, @to_currency, @to_currency, currencies
        )
        .order(valid_from: :desc)
        .pluck(:from_currency, :to_currency, :rate)

      loaded = {}
      rates_data.each do |from_curr, to_curr, rate|
        if from_curr == @to_currency
          loaded[to_curr] ||= (1.0 / rate) if rate && rate > 0
        else
          loaded[from_curr] = rate unless loaded.key?(from_curr)
        end
      end

      loaded
    end

    def load_cross_rates(currencies)
      base = ExchangeRate.cross_rate_base[@source]
      return {} unless base
      return {} if @to_currency == base

      # Filter to currencies that need cross-rate (not the base itself)
      need_cross = currencies.reject { |c| c == base }
      return {} if need_cross.empty?

      loaded = {}

      # Get base -> to_currency rate (e.g., EUR -> CHF)
      base_to_target = ExchangeRate.find_rate_on(base, @to_currency, @date, @source) ||
                       ExchangeRate.find_rate_on(base, @to_currency, (@date - 1.month).end_of_month, @source)
      return {} unless base_to_target

      # For each missing currency, get currency -> base rate
      need_cross.each do |curr|
        curr_to_base = ExchangeRate.find_rate_on(curr, base, @date, @source) ||
                       ExchangeRate.find_rate_on(curr, base, (@date - 1.month).end_of_month, @source)
        if curr_to_base
          loaded[curr] = curr_to_base * base_to_target
        end
      end

      loaded
    end
  end
end
