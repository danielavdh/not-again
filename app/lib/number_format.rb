# frozen_string_literal: true

# How grouped money is written — thousands separator, decimal separator, and
# which side the currency symbol sits — as a per-admin choice with a per-
# language default.
#
# A choice rather than the current language's convention because the number's
# SHAPE is the reader's to pick, independent of the UI language: a Swiss
# bookkeeper working in German wants "CHF 1'234.56", a Norwegian "kr 1 234,56".
# The eight FORMATS below are every distinct shape in use across Europe. In the
# picker the currency slot shows "¤" so a row names a shape without implying a
# currency; the real symbol goes in at render.
#
# Held as literal data rather than read from locale files: the extra locales
# (de-CH, fr, …) are not in I18n.available_locales, so the i18n backend never
# loads their number blocks — and adding them there would make them selectable
# UI languages, which they must not be.
module NumberFormat
  # slug => { delimiter: (thousands), separator: (decimal), symbol: (%u/%n
  # layout) }
  FORMATS = {
    "uk"       => { delimiter: ",", separator: ".", symbol: "%u%n"  }, # ¤1,234.56    UK, Ireland, Israel
    "uk_after" => { delimiter: ",", separator: ".", symbol: "%n %u" }, # 1,234.56 ¤
    "tr"       => { delimiter: ".", separator: ",", symbol: "%u%n"  }, # ¤1.234,56    Türkiye (banking)
    "at"       => { delimiter: ".", separator: ",", symbol: "%u %n" }, # ¤ 1.234,56   Austria, Netherlands, Belgium
    "de"       => { delimiter: ".", separator: ",", symbol: "%n %u" }, # 1.234,56 ¤   Germany, Italy, Spain, Portugal, Greece
    "ch"       => { delimiter: "'", separator: ".", symbol: "%u %n" }, # ¤ 1'234.56   Switzerland, Liechtenstein
    "no"       => { delimiter: " ", separator: ",", symbol: "%u %n" }, # ¤ 1 234,56   Norway, Iceland
    "fr"       => { delimiter: " ", separator: ",", symbol: "%n %u" }, # 1 234,56 ¤   France, Nordics, CEE, Ukraine, Baltics
  }.freeze

  # UI language => its default slug when the admin has not chosen one. A
  # language not listed falls through to reading its own rails-i18n block.
  DEFAULT_FOR = { "en" => "uk", "de" => "de", "es" => "de", "nl" => "at" }.freeze

  class << self
    # The format in effect for an admin: their explicit choice, else the UI
    # language's default. Always returns { delimiter:, separator:, symbol: }.
    def resolve(preferred, locale = I18n.locale)
      FORMATS[preferred.to_s.presence] || default_for(locale)
    end

    def default_for(locale)
      FORMATS[DEFAULT_FOR[locale.to_s]] || from_locale(locale)
    end

    # A UI language with no DEFAULT_FOR entry: take its own rails-i18n currency
    # block (it is a loaded locale, being a UI language).
    def from_locale(locale)
      c = I18n.t("number.currency.format", locale: locale, default: {})
      {
        delimiter: c[:delimiter].presence || ",",
        separator: c[:separator].presence || ".",
        symbol:    c[:format].presence    || "%u%n"
      }
    end

    # For the <select>: [[sample, slug], …] in FORMATS order. The sample is the
    # shape itself with ¤ where the symbol goes, so it needs no translation.
    def menu
      FORMATS.map { |slug, f| [sample(f), slug] }
    end

    def sample(f)
      number = "1#{f[:delimiter]}234#{f[:separator]}56"
      f[:symbol].sub("%u", "¤").sub("%n", number)
    end

    def valid?(slug)
      slug.blank? || FORMATS.key?(slug.to_s)
    end

    # What the #number-format-config element hands the JS (getNumberFormat).
    def js_config(preferred, locale = I18n.locale)
      resolve(preferred, locale).slice(:separator, :delimiter)
    end
  end
end
