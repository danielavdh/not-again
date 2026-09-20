# frozen_string_literal: true
require "csv"

module Archives
  # The whole ledger, every account, for one SCOPE across one CALENDAR YEAR —
  # posting-level, not journal-entry-level: a mixed-currency entry cannot be
  # faithfully described by one summed amount per entry, and fidelity is the
  # entire point of an archive meant to outlive this app.
  #
  # Each entity's rows are limited to the days it actually belonged to this
  # scope that year (Entity.scope_windows_for). `through:` caps the year at a
  # mid-year date, and is only for the deletable on-demand snapshot; a year-end
  # archive always runs the whole year.
  #
  # Closing entries are INCLUDED, unlike every other export in the app — an
  # archive that omitted them could not reconstruct what was filed.
  #
  # ONE SHAPE, ALWAYS — see csv_with. Unlike the report CSVs, an archive is
  # written by a background job as well as by an admin, so a locale-dependent
  # shape would record who or what generated the file rather than anything
  # about the books.
  class BooksCsv
    HEADER = %w[EntryID Date Entity AccountCode AccountName DebitMinor CreditMinor Currency Memo JournalReference].freeze

    def initialize(scope_key:, year:, through: nil)
      @scope_key = scope_key
      @year      = year
      @through   = through
    end

    def generate
      windows = Entity.scope_windows_for(scope_key: @scope_key, year: @year)

      conditions = []
      binds = []
      windows.each do |code, ranges|
        ranges.each do |from, to|
          to = [ to, @through ].min if @through
          next if from > to
          conditions << "(SUBSTRING(accounts.code, 2, 2) = ? AND journal_entries.entry_date BETWEEN ? AND ?)"
          binds.concat([ code, from, to ])
        end
      end

      return csv_with([]) if conditions.empty?

      rows = Posting.joins(:account, :journal_entry)
        .joins(Posting.currency_join_sql)
        .where(journal_entries: { posted: true })
        .where([ conditions.join(" OR "), *binds ])
        .order("journal_entries.entry_date, journal_entries.id, accounts.code")
        .pluck(
          "journal_entries.id", "journal_entries.entry_date",
          Arel.sql("SUBSTRING(accounts.code, 2, 2)"), "accounts.code", "accounts.name",
          "postings.entry_type", "postings.amount", Arel.sql(Posting.effective_currency_sql),
          "journal_entries.memo", "journal_entries.journal_reference"
        )

      csv_with(rows)
    end

    private

    # Amounts are written as MINOR UNITS — the stored integer, undivided — and
    # the separator is fixed. There is no decimal separator that imports
    # cleanly in every locale: "95.00" read where the comma is decimal becomes
    # 9500, silently and as a NUMBER, so it sums. An integer cannot be misread
    # that way, and it is also the exact stored value, which is what an archive
    # meant to outlive this app should carry. Dates are ISO and the header is
    # English for the same reason.
    def csv_with(rows)
      CSV.generate(col_sep: ",") do |csv|
        csv << HEADER
        # entry_type comes back as the string enum key ("debit"/"credit"), not
        # the raw integer: pluck on a joined query casts it.
        rows.each do |id, date, entity_code, code, name, entry_type, amount, currency, memo, ref|
          debit  = entry_type == "debit" ? amount : ""
          credit = entry_type == "debit" ? "" : amount
          csv << [ id, date.strftime("%Y-%m-%d"), entity_code, code, name, debit, credit, currency, memo, ref ]
        end
      end
    end
  end
end
