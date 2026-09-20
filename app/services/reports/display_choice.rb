# frozen_string_literal: true

module Reports
  # What the converted column is showing: a currency, and which published series
  # produced it. Being able to read the same books at any accepted authority's
  # rates is the point — EUR at the ECB or at the BMF's §16(6) monthly average,
  # CHF at ESTV or cross-rated through the ECB.
  #
  # ONE PARAMETER, not two. The choice rides in `currency` as "CHF:estv",
  # because every existing link, bookmark and form already sends ?currency=CHF.
  # A bare currency still means "the usual source for that currency", so old
  # links keep working exactly as they did.
  #
  # Parsing lives here rather than in four controller actions.
  class DisplayChoice
    SEPARATOR = ":"

    attr_reader :currency, :source

    # `available:` is the currency whitelist. A currency outside it is refused
    # and the fallback used instead — this reads a URL parameter, so it must not
    # be trusted to name anything.
    def self.parse(value, available:, fallback:)
      currency, source = value.to_s.split(SEPARATOR, 2)
      currency = currency.to_s.upcase.presence

      # A rejected currency takes its source with it. Otherwise "XXX:bundesbank"
      # would fall back to EUR and quietly keep the Bundesbank — a source the
      # user did not choose, for a currency they did not choose. Half of a
      # refused request is not a request.
      return new(fallback) unless currency.in?(Array(available).map(&:to_s))

      new(currency, source)
    end

    # Options for the converted-column dropdown, grouped so the currencies this
    # installation actually keeps books in come first and are visibly apart from
    # the rest. <optgroup> rather than a styled divider: the browser draws the
    # rule and the heading itself, it needs no CSS, and a screen reader
    # announces the grouping instead of skipping a decorative line. A single
    # group is returned FLAT, since an optgroup containing everything is a
    # heading that divides nothing.
    #
    # Lives here rather than in RateSourceConfig because the split is by USAGE,
    # an accounts question, and RateSourceConfig is tier 1 and knows nothing
    # about accounts.
    #
    # `in_use:` is the [currency, source] the report ACTUALLY read, and it earns
    # an option only when it is a cross-rate — "CHF via ECB". Those are never
    # offered as a choice, but a select can only SHOW an option that exists in
    # its list, so the one in use has to be there or the browser falls back to
    # displaying the first entry and the menu contradicts the column.
    def self.grouped_options(currencies, labels:, in_use: nil)
      used, rest = Array(currencies).partition { |c| Currency.used_codes.include?(c) }
      options    = ->(list) { RateSourceConfig.display_options(list) + via_option(list, in_use) }

      return options.call(currencies) if used.empty? || rest.empty?

      { labels[:in_use] => options.call(used), labels[:others] => options.call(rest) }
    end

    def self.via_option(list, in_use)
      return [] if in_use.blank?

      currency, source = in_use
      return [] unless list.include?(currency)
      return [] unless RateSourceConfig.cross_rate?(currency, source)

      # The label is computed first on purpose: LocaleCoverageTest reads t()
      # calls with a regex that stops at the first ")", so a nested call hides
      # the `default:` from it and the key is reported missing.
      label = RateSourceConfig.short_label_for(source)
      text  = I18n.t("reports.currency_via", currency: currency, source: label, default: "%{currency} via %{source}")

      [ [ text, "#{currency}#{SEPARATOR}#{source}" ] ]
    end

    def initialize(currency, source = nil)
      @currency = currency
      # A source is honoured only if it is declared AND can actually reach this
      # currency. Anything else silently becomes the default rather than
      # producing an empty column — a URL is not a promise.
      @source = source.presence
      @source = nil unless @source && RateSourceConfig.sources_for_display(@currency).include?(@source)
    end

    # nil unless the user picked a source, so the translator falls through to
    # tier 1 (or, for a tax report, to the country's rule) exactly as before.
    def sources
      source ? [ source ] : nil
    end

    # What goes back in a link or a hidden field. Stays BARE when no source was
    # chosen, so URLs keep the short readable form they have always had.
    def to_param
      source ? "#{currency}#{SEPARATOR}#{source}" : currency
    end

    # What the DROPDOWN must be given, and it is not to_param.
    #
    # Every option's value is "CURRENCY:source". On landing there is no
    # ?currency= at all, so to_param is a bare "EUR" — which matches no option,
    # and a browser given a selected value it cannot find falls back to
    # displaying the FIRST option in the list. So the select always gets the
    # explicit source, defaulting to the one the report is actually reading.
    def to_option
      "#{currency}#{SEPARATOR}#{effective_source}"
    end

    # The source actually in use: the chosen one, or the head of what tier 1
    # offers for this currency — the same value the options list leads with, so
    # a match is guaranteed.
    def effective_source
      source || RateSourceConfig.sources_for_display(currency).first
    end

    def ==(other)
      other.is_a?(self.class) && to_param == other.to_param
    end
  end
end
