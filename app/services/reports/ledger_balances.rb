# frozen_string_literal: true

module Reports
  # THE posting aggregation. Every report figure in the app is a signed sum of
  # postings grouped by account, currency and a time bucket, and this is the one
  # place that query lives — written six times before, each with its own answer
  # for the bucket, for whether closing entries count, and for the sign of an
  # account, which is how the same books could show different numbers on
  # different screens.
  #
  # What varies is passed in:
  # bucket:          :total | :month | :day — how finely to group by date. A
  # monthly rate source needs :month, a daily one :day, a position-at-a-date
  # (balance sheet) :total.
  # include_closing: whether year-end closing entries are in the sum (balance
  # sheet yes; P&L, trial balance and tax no).
  # net:             true → one signed figure per (account, currency, bucket),
  # signed by Account#debit_normal?. false → { debit:, credit: } kept apart, for
  # the trial balance.
  #
  # Groups in SQL, plucks scalars, never loads a Posting. #line_items is the
  # opt-in per-posting detail a custom report needs.
  class LedgerBalances
    # The debit-normal account types — the data side of Account#debit_normal?,
    # kept next to the rule it mirrors, with a test asserting they agree. Names,
    # not ids: a pluck of the enum column hands back the key string in Rails
    # 8.1.
    DEBIT_NORMAL_TYPES = %w[asset expense personal].freeze

    # nil = don't group by date at all (:total collapses the whole range into
    # one bucket, which the reader then dates at `to`).
    BUCKET_SQL = {
      total: nil,
      month: "date_trunc('month', journal_entries.entry_date)",
      day:   "date_trunc('day', journal_entries.entry_date)"
    }.freeze

    # Pass `accounts:` (loaded Account objects) when the caller already has them
    # and the type map is free; pass `account_ids:` otherwise, at the cost of
    # one small query.
    def initialize(to:, accounts: nil, account_ids: nil, from: nil, bucket: :month,
                   include_closing: false, net: true)
      if accounts
        @account_ids   = accounts.map(&:id)
        @account_types = accounts.to_h { |a| [ a.id, a.account_type ] }
      else
        @account_ids   = Array(account_ids)
      end
      @from            = from
      @to              = to
      @bucket          = bucket
      @include_closing = include_closing
      @net             = net
    end

    # { account_id => { bucket_date(Date) => { currency => value } } }, where
    # value is a signed Integer (net: true) or { debit:, credit: } (net: false).
    # bucket_date is the month/day start, or `to` for :total.
    def call
      result = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = {} } }

      grouped_rows.each do |account_id, currency, period, debits, credits|
        next if currency.blank?
        bucket_date = period ? period.to_date : @to.to_date

        result[account_id][bucket_date][currency] =
          if @net
            DEBIT_NORMAL_TYPES.include?(account_type_of(account_id)) ? (debits - credits) : (credits - debits)
          else
            { debit: debits, credit: credits }
          end
      end

      # Plain hashes out — no default proc, so a caller's `[]` on an unknown
      # key returns nil rather than silently creating an entry.
      cleaned = {}
      result.each do |account_id, by_bucket|
        buckets = {}
        by_bucket.each do |bucket_date, by_curr|
          kept = by_curr.reject { |_, v| zero?(v) }
          buckets[bucket_date] = kept unless kept.empty?
        end
        cleaned[account_id] = buckets unless buckets.empty?
      end
      cleaned
    end

    # Per-posting rows, signed, for a report that shows individual line items. A
    # separate query on purpose — the grouped one above is what every other
    # caller wants, and it must stay cheap.
    Row = Struct.new(:account_id, :date, :currency, :amount, :memo,
                     :description, :journal_entry_id, :posting_id, keyword_init: true)

    def line_items
      base_scope
        .pluck(
          :account_id,
          Arel.sql(Posting.effective_currency_sql),
          :entry_type,
          :amount,
          Arel.sql("journal_entries.entry_date"),
          Arel.sql("journal_entries.memo"),
          :description,
          :journal_entry_id,
          Arel.sql("postings.id")
        )
        .filter_map do |account_id, currency, entry_type, amount, date, memo, description, je_id, posting_id|
          next if currency.blank?
          is_debit     = entry_type == "debit" || entry_type == 0
          debit_normal = DEBIT_NORMAL_TYPES.include?(account_type_of(account_id))
          signed = if debit_normal
                     is_debit ? amount : -amount
                   else
                     is_debit ? -amount : amount
                   end
          Row.new(account_id: account_id, date: date, currency: currency, amount: signed,
                  memo: memo, description: description, journal_entry_id: je_id, posting_id: posting_id)
        end
    end

    private

    def zero?(value)
      value.is_a?(Hash) ? (value[:debit] == 0 && value[:credit] == 0) : value == 0
    end

    # account_type name ("asset", "income", …), keyed by id.
    def account_type_of(account_id)
      @account_types ||= Account.where(id: @account_ids).pluck(:id, :account_type).to_h
      @account_types[account_id]
    end

    def base_scope
      scope = Posting
        .joins(:journal_entry, :account)
        .joins(Posting.currency_join_sql)
        .where(account_id: @account_ids)
        .where(journal_entries: { posted: true })
        .where("journal_entries.entry_date <= ?", @to)
      scope = scope.where("journal_entries.entry_date >= ?", @from) if @from
      scope = scope.where("journal_entries.closing_entry IS NOT TRUE") unless @include_closing
      scope
    end

    def grouped_rows
      currency_sql = Posting.effective_currency_sql
      bucket_sql   = BUCKET_SQL.fetch(@bucket) # nil for :total
      groups       = [ :account_id, Arel.sql(currency_sql), *(Arel.sql(bucket_sql) if bucket_sql) ]
      selects      = [
        :account_id,
        Arel.sql(currency_sql),
        Arel.sql(bucket_sql || "NULL"),
        Arel.sql("SUM(CASE WHEN postings.entry_type = 0 THEN postings.amount ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN postings.entry_type = 1 THEN postings.amount ELSE 0 END)")
      ]
      base_scope.group(*groups).pluck(*selects)
    end
  end
end
