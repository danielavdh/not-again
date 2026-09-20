# frozen_string_literal: true

# Computes the next fiscal period an entity should close, per entity.
#
# The fiscal-year pattern is NOT stored on the entity. It lives implicitly in
# the entity's closing entries, in their period_start and period_end. The first
# close establishes it from a chosen pattern plus the business's earliest entry;
# every subsequent close derives the next period from the last closing entry
# (period_end + 1 day … + 1 year), which carries a stub first year cleanly into
# full years.
#
# Skip-and-advance: elapsed periods with nothing to close — dormant years, or a
# pro user's same-pattern hand-closed history — are stepped over until a period
# with real income or expense is found, or the current unfinished year is
# reached.
class FiscalPeriod
  class InvalidYearEnd < StandardError; end

  Result = Struct.new(:status, :start_date, :end_date, :backlog, keyword_init: true) do
    def ready?        = status == :ready
    def not_finished? = status == :not_finished
    def none?         = status == :none
  end

  # Recognised fiscal-year ends: [month, day]. "other" supplies its own.
  YEAR_ENDS = {
    "calendar" => [12, 31], # 1 Jan – 31 Dec
    "uk"       => [4, 5],   # 6 Apr – 5 Apr (self-employment / personal)
    "uk_fy"    => [3, 31],  # 1 Apr – 31 Mar (UK financial year)
  }.freeze

  def self.next_for(entity, pattern: nil, year_end_month: nil, year_end_day: nil)
    new(entity, pattern:, year_end_month:, year_end_day:).next_period
  end

  # End date of the entity's most recent closing entry, or nil. Drives the
  # dashboard "closed up to" note.
  def self.last_closed_on(entity)
    JournalEntry
      .where(posted: true, closing_entry: true)
      .joins(postings: :account)
      .where("SUBSTRING(accounts.code, 2, 2) = ?", entity.code)
      .maximum(:period_end)
  end

  # The same answer for a whole set of entities in ONE query, keyed by entity
  # code. The dashboard renders _overview once per entity, and calling
  # last_closed_on inside that loop was a MAX-with-join each.
  # BaseController#last_closed_on builds this once per request.
  def self.last_closed_on_by_code(entity_codes)
    codes = Array(entity_codes).compact.uniq
    return {} if codes.empty?

    JournalEntry
      .where(posted: true, closing_entry: true)
      .joins(postings: :account)
      .where("SUBSTRING(accounts.code, 2, 2) IN (?)", codes)
      .group(Arel.sql("SUBSTRING(accounts.code, 2, 2)"))
      .maximum(:period_end)
  end

  def initialize(entity, pattern: nil, year_end_month: nil, year_end_day: nil)
    @entity = entity
    if pattern && YEAR_ENDS.key?(pattern)
      @year_end_month, @year_end_day = YEAR_ENDS[pattern]
    else
      @year_end_month = year_end_month
      @year_end_day   = year_end_day
    end
  end

  def next_period
    start_date, end_date = first_candidate
    return Result.new(status: :none) unless start_date

    loop do
      return Result.new(status: :not_finished, start_date:, end_date:, backlog: false) if end_date >= Date.current

      unless period_empty?(start_date, end_date)
        return Result.new(status: :ready, start_date:, end_date:, backlog: (end_date + 1.year) < Date.current)
      end

      # Elapsed but nothing to close → step over it to the next period.
      start_date = end_date + 1.day
      end_date   = end_date + 1.year
    end
  end

  private

  attr_reader :entity

  # The first period to consider: derived from the last closing entry if one
  # exists, otherwise the business's first period built from the chosen pattern.
  def first_candidate
    if (anchor = last_closing_period_end)
      [anchor + 1.day, anchor + 1.year]
    else
      first_period_from_pattern
    end
  end

  def first_period_from_pattern
    return [nil, nil] unless @year_end_month && @year_end_day

    start = business_start
    return [nil, nil] unless start

    [start, first_year_end_on_or_after(start)]
  end

  def first_year_end_on_or_after(date)
    candidate = year_end_in(date.year)
    candidate < date ? year_end_in(date.year + 1) : candidate
  end

  def year_end_in(year)
    Date.new(year, @year_end_month, @year_end_day)
  rescue ArgumentError
    # e.g. 29 Feb in a non-leap year — not a valid recurring year-end.
    raise InvalidYearEnd
  end

  # Latest period_end among this entity's closing entries, or nil.
  def last_closing_period_end
    self.class.last_closed_on(entity)
  end

  # Earliest ordinary (non-closing) posted entry for this entity — the books'
  # first activity, used as the stub first year's start.
  def business_start
    JournalEntry
      .where(posted: true, closing_entry: false)
      .joins(postings: :account)
      .where("SUBSTRING(accounts.code, 2, 2) = ?", entity.code)
      .minimum(:entry_date)
  end

  def period_empty?(start_date, end_date)
    YearEndService.new(entity:, start_date:, end_date:).nothing_to_close?
  end
end
