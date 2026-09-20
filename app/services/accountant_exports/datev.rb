# frozen_string_literal: true

require "csv"

module AccountantExports
  # DATEV Buchungsstapel (EXTF), the format German and Austrian Treuhänder and
  # Steuerberater import into DATEV. Also the nearest thing accountancy has to a
  # lingua franca outside Germany — Swiss packages such as bexio and Banana
  # import it too, which is why Switzerland has no format of its own here.
  #
  # The shape is DATEV's, and every oddity below is theirs: semicolon separated;
  # "S"/"H" for Soll/Haben rather than a signed amount; comma as the decimal
  # mark; Belegdatum as DDMM only, with the year coming from the header;
  # Buchungstext capped at 60 characters.
  class Datev < Base
    HEADER_ROW = [
      "Umsatz", "S/H", "WKZ", "Kurs", "Basis-Umsatz", "WKZ Basis-Umsatz",
      "Konto", "Gegenkonto (ohne BU-Schlüssel)", "BU-Schlüssel",
      "Belegdatum", "Belegfeld 1", "Belegfeld 2", "Skonto", "Buchungstext"
    ].freeze

    def self.label    = "DATEV (EXTF Buchungsstapel)"
    def self.filename = "EXTF_Buchungsstapel.csv"

    def generate
      CSV.generate(col_sep: ";", encoding: "UTF-8") do |csv|
        csv << file_header
        csv << HEADER_ROW
        postings.each do |posting|
          row = row_for(posting)
          csv << row if row
        end
      end
    end

    private

    # DATEV's own metadata line. The fixed values identify the format version
    # ("EXTF", 700) and the record type (21 = Buchungsstapel).
    def file_header
      [
        "EXTF", 700, 21, "Buchungsstapel", 12, nil,
        nil, nil, nil, nil,
        entity.code,
        nil,
        start_date.beginning_of_year.strftime("%Y%m%d"),
        entity.code.length,
        start_date.strftime("%Y%m%d"),
        end_date.strftime("%Y%m%d"),
        nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
      ]
    end

    # DATEV books one line per pair, so a nominal posting needs the balance
    # account facing it. An entry without one cannot be expressed, and is
    # skipped rather than guessed at.
    def row_for(posting)
      counter = posting.journal_entry.postings.find { |p| p.account&.balance_account? }
      return nil unless counter

      je = posting.journal_entry
      [
        format("%.2f", posting.amount / 100.0).tr(".", ","),
        posting.debit? ? "S" : "H",
        counter.currency || "",
        "", "", "",
        posting.account.code,
        counter.account.code,
        "",
        je.entry_date.strftime("%d%m"),
        je.journal_reference || "",
        posting.reference || "",
        "",
        (posting.description.presence || je.memo || "").truncate(60)
      ]
    end
  end
end
