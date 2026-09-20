# frozen_string_literal: true

module Archives
  # Decides WHICH calendar years to write an undeletable archive for, and WHEN.
  #
  # A year Y for a scope is written the first time either is true: every member
  # with activity in its Y-window has closed through that window's end, or it is
  # 1 January of Y+2 and still nobody has (Archives::SweepJob). After it exists,
  # any later data change dated in Y regenerates it in place. It is never
  # deleted and never split.
  #
  # Closing stays fiscal — a UK entity closes Apr–Mar — and this only reads one
  # number per entity, FiscalPeriod.last_closed_on, which a fiscal close
  # naturally pushes past a calendar year-end.
  class YearEnd
    # After entity E closes a fiscal period: write any now-ready calendar years
    # for whatever scope E is in now, and refresh any already-written year the
    # close touched.
    def self.after_close(entity)
      scope_key = Storage.scope_key_for(entity)
      entries   = Storage.list(scope_key)

      candidate_years(scope_key).each do |year|
        if Storage.year_end_archived?(scope_key, year, entries: entries)
          Generate.call(scope_key: scope_key, year: year) # refresh — close may have added entries
        elsif fully_closed?(scope_key, year)
          Generate.call(scope_key: scope_key, year: year)
        end
      end
    end

    # 1 January safety net: force year `current - 2` for one scope if nothing
    # covers it yet. Used by Archives::SweepJob.
    def self.force(scope_key, year)
      return if Storage.year_end_archived?(scope_key, year)
      Generate.call(scope_key: scope_key, year: year)
    end

    # A correction landed on `date`; if that year's archive exists, rebuild it.
    def self.refresh(scope_key, date)
      year = date.year
      return unless Storage.year_end_archived?(scope_key, year)
      Generate.call(scope_key: scope_key, year: year)
    end

    # A family dropped below two members and no sibling close will ever fire
    # again — write every outstanding calendar year for it, up to last year.
    def self.flush(scope_key)
      candidate_years(scope_key).each do |year|
        next if Storage.year_end_archived?(scope_key, year)
        Generate.call(scope_key: scope_key, year: year)
      end
    end

    # Every member whose postings fall in its Y-window for this scope has closed
    # through that window's end. A member with no postings in its window does
    # not block, since it can never "close" an empty year.
    def self.fully_closed?(scope_key, year)
      windows = Entity.scope_windows_for(scope_key: scope_key, year: year)
      return false if windows.empty?

      last_closed = FiscalPeriod.last_closed_on_by_code(windows.keys)
      windows.all? do |code, ranges|
        window_end = ranges.map(&:last).max
        next true unless activity?(code, ranges)
        (lc = last_closed[code]) && lc >= window_end
      end
    end

    # Calendar years this scope could owe an archive for: from its earliest
    # membership stint to last year. A handful of iterations for any real
    # installation.
    def self.candidate_years(scope_key)
      earliest =
        if scope_key.start_with?("g")
          EntityGroupMembership.where(entity_group_id: scope_key.delete_prefix("g").to_i).minimum(:starts_on)
        else
          EntityGroupMembership.joins(:entity)
            .where(entities: { code: scope_key }, entity_group_id: nil).minimum(:starts_on)
        end
      return [] unless earliest

      (earliest.year..(Date.current.year - 1)).to_a
    end

    def self.activity?(entity_code, ranges)
      clause = ranges.map { "journal_entries.entry_date BETWEEN ? AND ?" }.join(" OR ")
      Posting.joins(:journal_entry, :account)
        .where(journal_entries: { posted: true })
        .where("SUBSTRING(accounts.code, 2, 2) = ?", entity_code)
        .where([ clause, *ranges.flatten ])
        .exists?
    end
    private_class_method :activity?
  end
end
