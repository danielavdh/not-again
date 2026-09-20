# frozen_string_literal: true

module CurrencyConfig
  
  # NO LONGER THE LIST. This is the SEED and the FALLBACK.
  #
  # The list an installation actually supports lives in `currencies`, where an
  # admin can add to it. This constant is what that table was seeded from, and
  # what every reader below falls back to when the table cannot be read: before
  # db:create, during assets:precompile, in CI with no database, and in the
  # window between deploying new code and running the migration.
  #
  # Do not add a currency here expecting it to appear. Add a row.
  SYMBOLS = {
    'GBP' => '£',
    'EUR' => '€',
    'USD' => '$',
    'CHF' => 'CHF '
  }.freeze

  class << self
    # code => symbol, from the table, falling back to SYMBOLS. The one place
    # that decides where the list comes from; everything else asks this.
    #
    # EVERY currency the installation knows, active or not. Used for RENDERING —
    # what an amount already booked in a currency looks like. A deactivated
    # currency must keep its symbol, or every historical figure in it silently
    # loses one.
    def symbols
      (defined?(Currency) && Currency.cached_symbols) || SYMBOLS
    end

    # THE list of currencies this installation supports, in display order.
    #
    # A method rather than a constant on purpose: a constant frozen at boot
    # would go stale until a restart — an admin would add a currency, the next
    # fetch would ignore it, and nothing would say why.
    #
    # ACTIVE ONLY — what a dropdown may OFFER, which is a different question
    # from what an amount looks like. `symbols` answers the other one.
    def available
      (defined?(Currency) && Currency.cached_available) || SYMBOLS.keys
    end

    # Where a currency sorts in reports and dropdowns — the order SYMBOLS is
    # written in. Unknown currencies fall to the end rather than raising.
    def sort_index(code)
      available.index(code) || 999
    end

    def symbol_for(currency)
      symbols[currency&.upcase] || ''
    end

    # Everything the app might see in front of or behind a number: every symbol
    # AND every code in SYMBOLS. Longest first, so "CHF" is removed whole rather
    # than leaving "HF" behind after a shorter match.
    #
    # Derived from SYMBOLS rather than hardcoded, so adding a currency there
    # really is the only step. A fixed /[£€$]/ meant CHF never parsed on paste,
    # and every non-Latin symbol — лв., lei, ₴, zł — would have failed the same
    # way, silently, as a blank field.
    #
    # Memoised against the LIST, not forever. A plain ||= meant a currency added
    # while the app was running failed to parse on paste until the next restart;
    # no memo at all meant rebuilding a Regexp.union on every amount parsed,
    # which is fine for four currencies and not for fifty. Comparing the small
    # hash is cheap, so it rebuilds exactly when the supported list changes.
    def symbol_pattern
      current = symbols
      if @symbol_pattern.nil? || @symbol_pattern_for != current
        @symbol_pattern_for = current
        @symbol_pattern = Regexp.union(
          (current.values.map(&:strip) + current.keys)
            .reject(&:empty?)
            .uniq
            .sort_by { |s| -s.length }
        )
      end
      @symbol_pattern
    end

    # Free-text money to integer cents. Locale-INDEPENDENT on purpose: an amount
    # reads the same whatever language the page is in, so a figure pasted from a
    # statement in another format still lands right.
    #
    # The mirror of this exact algorithm is parseAmountToCents in
    # scripts/utils.js, and THE TWO MUST AGREE, or the on-screen running total
    # and the stored value drift apart. Change one, change the other;
    # currency_config_test's parity table and test/system/amount_input_test.rb
    # guard the seam.
    def parse_to_cents(value)
      return nil if value.blank?
      return value if value.is_a?(Integer)

      str = value.to_s.strip
      return nil if str.empty?

      # Handle negative
      negative = str.start_with?('-')
      str = str.sub(/^-/, '')

      # Remove any currency symbol or code this app knows about.
      str = str.gsub(symbol_pattern, '')

      # Whitespace is never a decimal separator — only a thousands separator or
      # padding — so it all goes before the separators are read. Covers the
      # plain space, the non-breaking space and the narrow no-break space, which
      # is what most of eastern and northern Europe actually types: "1 234,56".
      str = str.gsub(/[[:space:]\u00A0\u202F']/, '')

      # Anything non-numeric still clinging to either END is a currency marker
      # not yet known — лв., lei, ₴, zł, kr, or a bare ISO code. Strip it, so a
      # currency works on paste BEFORE anyone remembers to add it to SYMBOLS.
      # Ends only, deliberately: "12abc34" is not a number and must still fail.
      str = str.sub(/\A[^\d]+/, '').sub(/[^\d]+\z/, '')

      # What survives is digits, '.' and ',' only. Anything else — an embedded
      # letter, stray punctuation — is a typo, not a decorated number.
      return nil unless str.match?(/\A[\d.,]+\z/)

      # Which of '.' and ',' is the decimal separator? The RIGHTMOST of the two,
      # the other being thousands grouping. With only one kind present, a single
      # occurrence followed by exactly three digits is the genuinely ambiguous
      # "1.234 / 1,234" — read as grouping, because money is not written to
      # three decimal places.
      last_dot   = str.rindex('.')
      last_comma = str.rindex(',')
      decimal =
        if last_dot && last_comma
          last_dot > last_comma ? '.' : ','
        elsif (sep = last_dot ? '.' : (last_comma ? ',' : nil))
          str.count(sep) == 1 && str.split(sep, -1).last.length != 3 ? sep : nil
        end

      # Whatever is called grouping must be well-formed threes, or the string is
      # malformed ("1,234,56") and returns nil rather than a confident wrong
      # number.
      grouped = /\A\d{1,3}([.,]\d{3})*\z|\A\d*\z/
      if decimal
        int_part, _, frac_part = str.rpartition(decimal)
        return nil unless int_part.match?(grouped)
        str = "#{int_part.delete('^0-9')}.#{frac_part.delete('^0-9')}"
      else
        return nil unless str.match?(grouped)
        str = str.delete('^0-9')
      end
      return nil if str.delete('.').empty?

      cents = (BigDecimal(str) * 100).round.to_i
      negative ? -cents : cents
    rescue ArgumentError, TypeError
      nil
    end

    # The grouping, decimal separator and symbol layout in effect: the admin's
    # preferred_number_format (carried on Current) if set, else the UI
    # language's default. See NumberFormat.
    def number_format(locale = I18n.locale)
      NumberFormat.resolve((defined?(Current) && Current.number_format), locale)
    end

    def format_display(val, locale: I18n.locale)
      return nil if val.nil?
      nf = number_format(locale)
      int_part, dec_part = sprintf('%.2f', val.abs).split('.')
      result = nbsp("#{group(int_part, nf[:delimiter])}#{nf[:separator]}#{dec_part}")
      val.negative? ? "-#{result}" : result
    end

    def format_cents(cents, currency = nil, locale: I18n.locale)
      return '' if cents.nil?

      amount = cents / 100.0
      nf = number_format(locale)

      int_part, dec_part = sprintf('%.2f', amount.abs).split('.')
      number = "#{group(int_part, nf[:delimiter])}#{nf[:separator]}#{dec_part}"

      # WHERE the symbol goes rides with the number format, not the language: a
      # person who picks "1'234.56" almost certainly wants "CHF" in front of it
      # too. %u is the unit, %n the number. symbol_for may carry its own
      # trailing space, so "%u%n" still separates them; squeeze so it does not
      # double against a "%u %n".
      symbol = currency ? symbol_for(currency) : ''
      result = nbsp(nf[:symbol].sub('%u', symbol).sub('%n', number).squeeze(' ').strip)

      amount.negative? ? "-#{result}" : result
    end

    # An amount is one thing — no space inside it (symbol gap, thousands) may
    # break onto a second line. parse_to_cents strips U+00A0, so round-trips
    # hold.
    def nbsp(str)
      str.tr(' ', " ")
    end

    # "1234567" -> "1'234'567" etc.
    def group(digits, delimiter)
      digits.reverse.gsub(/(\d{3})(?=\d)/, '\\1' + delimiter).reverse
    end

    # A NUMBER IN A SPREADSHEET IS NOT A NUMBER IN A STRING.
    #
    # Writing "2300.05" whatever language the user is in means that, opened in a
    # German, Dutch or Spanish Excel — where the decimal separator is a comma —
    # the column arrives as TEXT, and every total the accountant tries to take
    # comes out empty or wrong. Silently, because a spreadsheet does not
    # complain about text. So the decimal separator follows the FORMAT in
    # effect, the same one the screen uses.
    #
    # NO THOUSANDS SEPARATOR, deliberately. "2.300,05" is how a German writes it
    # on paper, but a spreadsheet reading a file wants the digits unbroken: the
    # grouping is the reader's job, applied by cell format, and a stray dot
    # inside a number is the fastest way to have it parsed as text again.
    #
    # See csv_separator: a comma decimal forces a semicolon column separator, or
    # the two collide and the whole file lands in one column.
    def format_cents_csv(cents, locale: I18n.locale)
      return '' if cents.nil?

      formatted = '%.2f' % (cents / 100.0)
      sep = number_format(locale)[:separator]
      sep == '.' ? formatted : formatted.tr('.', sep)
    end

    # ";" wherever the decimal separator is a comma, so the decimal and the
    # column separator do not collide and drop the whole file into one column.
    # Excel's own convention, and what AccountantExports::Datev has always done.
    def csv_separator(locale: I18n.locale)
      number_format(locale)[:separator] == ',' ? ';' : ','
    end

    # What #number-format-config hands the JS (getNumberFormat) — the same
    # separator and delimiter the server formats with, so the on-blur reformat
    # and the running totals match what is saved.
    def js_format(locale: I18n.locale)
      number_format(locale).slice(:separator, :delimiter)
    end

  end
end