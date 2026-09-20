# frozen_string_literal: true

# Reads db/exchange_rate_rules.yml — TIER 2. Which rate a country's tax law
# accepts for a figure that is SUBMITTED.
#
# The line between this and RateSourceConfig is the point of both:
# RateSourceConfig knows what a source IS and names no country; this knows what
# a country ACCEPTS and describes no feed. A report on screen asks the first,
# only a submission asks the second.
class RateRuleConfig
  PATH = Rails.root.join("db", "exchange_rate_rules.yml")

  # WHICH DATE the rate is keyed to. A fixed vocabulary, because
  # ExchangeRate::Translator switches on it — a value nothing recognises would
  # read as though it did something and quietly behave as the default.
  #
  # transaction_date       the rate covering the day of the transaction.
  # preceding_publication  the last rate published BEFORE that day, where the
  # law keys to the publication rather than the transaction. Poland does this,
  # and so does any country whose source publishes DAILY, because a transaction
  # on a Saturday has no rate of its own.
  #
  # With a monthly source the two are identical: one span covers the whole
  # month, so the fallback never fires. The distinction only starts to matter
  # with a daily feed.
  TRANSACTION_DATE      = "transaction_date"
  PRECEDING_PUBLICATION = "preceding_publication"
  DATE_BASES = [ TRANSACTION_DATE, PRECEDING_PUBLICATION ].freeze

  class << self
    def all
      config.keys
    end

    def exists?(country)
      config.key?(key(country))
    end

    # The ordered list of sources this country's law accepts for a submission,
    # most preferred first; the rest are the fallback, used where the preferred
    # source has no rate covering the date.
    #
    # `scheme:` narrows it to one tax where a country's taxes differ. Germany is
    # the live case: income tax takes the ECB reference rate, Umsatzsteuer the
    # Bundesbank monthly average that §16(6) UStG names.
    #
    # Returns [] for a country with no rule, which callers must treat as "fall
    # back to tier 1" rather than "accept nothing".
    def accepted_sources(country, scheme: nil)
      Array(rule(country, scheme: scheme)["accepts"]).map(&:to_s)
    end

    # Every source named by ANY country's rule, at country level or in a scheme
    # override — which feeds somebody's tax law actually asks for.
    #
    # The question behind it is whether a source is worth FETCHING. A source
    # declared in exchange_rate_sources.yml is one the app can read; it becomes
    # one the app should pull nightly only when a rule names it, or when tier 1
    # displays through it. Otherwise a shipped installation fetches feeds for
    # countries it has never heard of — which matters most for a DAILY source,
    # at ~250 periods a year against 12.
    #
    # A SCHEME OVERRIDE ONLY COUNTS IF THE SCHEME EXISTS. A `schemes:` block may
    # name a tax nobody has written a catalogue for — Germany's umsatzsteuer
    # does, and the Dutch omzetbelasting does — which is deliberate and useful,
    # because the file states what the law requires. But such a rule can never
    # FIRE: `scheme:` reaches this file only from a report or a submission, and
    # both come from a tax category file. Counting its sources as wanted had the
    # app fetching the Bundesbank nightly for a German VAT return that does not
    # exist.
    def all_accepted_sources
      known = TaxSchemeConfig.all_schemes
      config.each_pair.flat_map { |country, rule|
        live = (rule["schemes"] || {}).select { |scheme, _| known.include?(scheme) }
        [ rule["accepts"] ] + live.values.map { |o| o["accepts"] }
      }.compact.flatten.map(&:to_s).uniq
    end

    # The first accepted source this installation actually has configured. A
    # rule may legitimately name one it does not carry — the file describes tax
    # law, not one deployment's feeds.
    def preferred_source(country, scheme: nil)
      accepted_sources(country, scheme: scheme).find { |s| RateSourceConfig.exists?(s) }
    end

    # Which date the rate is keyed to — one of DATE_BASES. Not always the
    # transaction date: Poland uses the last publication before the tax point,
    # and any country reading a DAILY feed needs the same rule for weekends and
    # public holidays.
    #
    # Defaults to the transaction date for a country with no rule, which is both
    # the commonest law and what the app did before this was wired up.
    #
    # This method once existed with NOTHING CALLING IT: the field was declared
    # in the YAML, documented in its header, and changed no behaviour
    # whatsoever. Grep for a caller before trusting a declared field.
    def date_basis_for(country, scheme: nil)
      value = rule(country, scheme: scheme)["date_basis"].to_s
      DATE_BASES.include?(value) ? value : TRANSACTION_DATE
    end

    # What to do when no accepted source carries the currency at all.
    def unpublished_currency_for(country, scheme: nil)
      rule(country, scheme: scheme)["unpublished_currency"]
    end

    # The taxes this country overrides — the keys of its `schemes:` block.
    # Without it, a caller wanting to know which taxes differ had to reach into
    # `config` and read the raw hash, which is memoisation rather than an
    # interface.
    def overridden_schemes(country)
      (config.dig(key(country), "schemes") || {}).keys
    end

    # One country's rule, with any per-scheme block merged over the top. Shallow
    # merge on purpose: a scheme overrides whole fields, never half of an
    # `accepts:` list.
    def rule(country, scheme: nil)
      base = config[key(country)] || {}
      return base.except("schemes") unless scheme

      override = base.dig("schemes", scheme.to_s) || {}
      base.except("schemes").merge(override)
    end

    def reload!
      @config = nil
    end

    def config
      @config ||= YAML.safe_load_file(PATH) || {}
    end

    private

    def key(country)
      country.to_s.downcase
    end
  end
end
