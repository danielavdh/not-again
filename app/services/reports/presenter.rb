# frozen_string_literal: true

module Reports
  # The shared pipeline behind a SAVED report. A custom report (grouped by
  # parent account) and a tax report (grouped by tax category) are the same
  # machine with a different grouping:
  #
  # 1. pull the report's ordered account set     (subclass: #ordered_accounts)
  # 2. aggregate every posting on it, signed     (Reports::LedgerBalances)
  # 3. translate each line at its own date's rate (subclass: #translation)
  # 4. a missing rate blanks the WHOLE converted column, all-or-nothing, the way
  # the three general reports do
  # 5. hand the subclass the per-account rows to group and total (subclass:
  # #build)
  class Presenter
    attr_reader :report, :display_currency, :short_version

    # `display_currency` is REQUIRED: everywhere else an unstated one falls back
    # to EUR worked out from the admin's accounts at login, and a silent second
    # answer in a report class is the wrong place to discover that.
    #
    # `sources:` is the series the reader chose in the dropdown; nil is the
    # ordinary case. A TAX report is never given one — its scheme declares both
    # the currency and the accepted series.
    def initialize(report:, display_currency:, short_version: true, admin:, sources: nil)
      @report           = report
      @display_currency = display_currency
      @short_version    = short_version
      @admin            = admin
      @sources          = sources
    end

    def generate
      accounts = ordered_accounts
      return empty_result if accounts.empty?

      @postings_data = load_postings_data(accounts)

      @currencies = @postings_data.values
        .flat_map { |d| d[:by_currency].keys }
        .uniq
        .sort_by { |c| CurrencyConfig.sort_index(c) }

      build(accounts)
    end

    private

    # ==== subclass hooks ===================================================

    # Loaded Account objects, in report order.
    def ordered_accounts
      raise NotImplementedError, "#{self.class} must supply #ordered_accounts"
    end

    # The Reports::Translation for this report (memoised in the subclass).
    def translation
      raise NotImplementedError, "#{self.class} must supply #translation"
    end

    # accounts → the output hash the view and the CSV exporter consume.
    def build(_accounts)
      raise NotImplementedError, "#{self.class} must supply #build"
    end

    def empty_result
      { report: report, display_currency: display_currency, currencies: [] }
    end

    # ==== shared machinery ================================================

    def rate_unavailable
      @rate_unavailable
    end

    def rate_sources_used
      translation.sources_used(@currencies || [])
    end

    # A missing rate is recorded and the figure becomes 0 rather than escaping:
    # letting it raise out of #generate would cost the ENTIRE report, per-
    # currency columns included.
    def translate_for_date(amount, currency, date)
      translation.translate_one(amount, currency, on: date, account_id: nil)
    rescue ExchangeRate::RateUnavailable => e
      @rate_unavailable ||= e
      0
    end

    # { account_id => { entries: [...], by_currency: { cur => cents },
    # translated_total: } }
    def load_postings_data(accounts)
      accounts_by_id = accounts.index_by(&:id)

      rows = Reports::LedgerBalances.new(
        accounts: accounts, from: report.start_date, to: report.end_date, include_closing: false
      ).line_items

      result = Hash.new { |h, k| h[k] = { entries: [], by_currency: Hash.new(0), translated_total: 0 } }

      rows.each do |row|
        next unless accounts_by_id[row.account_id]

        translated_amount = translate_for_date(row.amount, row.currency, row.date)

        result[row.account_id][:by_currency][row.currency] += row.amount
        result[row.account_id][:translated_total] += translated_amount
        result[row.account_id][:entries] << {
          date: row.date,
          description: row.description.presence || row.memo,
          currency: row.currency,
          amount: row.amount,
          translated_amount: translated_amount,
          journal_entry_id: row.journal_entry_id,
          posting_id: row.posting_id
        }
      end

      result.each_value { |v| v[:entries].sort_by! { |e| e[:date] } }

      # If ANY posting's rate was missing, blank the WHOLE converted column
      # rather than showing a total understated by the gap — the same all-or-
      # nothing the three general reports do. #rate_unavailable still carries
      # the reason, and format_cents_with_currency renders 0 as "".
      if @rate_unavailable
        result.each_value do |v|
          v[:translated_total] = 0
          v[:entries].each { |e| e[:translated_amount] = 0 }
        end
      end

      attach_edit_links(result)
      result
    end

    # Batch-load the balance-account leg of each entry, so the long form can
    # link a line to the deposit / withdrawal / transfer form that edits it.
    def attach_edit_links(result)
      je_ids = result.values.flat_map { |v| v[:entries].map { |e| e[:journal_entry_id] } }.uniq
      return if je_ids.empty?

      balance_info = @admin.accessible_postings
        .joins(:account)
        .where(journal_entry_id: je_ids)
        .where(accounts: { account_type: [ 1, 2, 3 ] })
        .pluck(:journal_entry_id, :account_id, :entry_type)
        .group_by(&:first)

      result.each_value do |v|
        v[:entries].each do |entry|
          info = balance_info[entry[:journal_entry_id]]
          next unless info

          if info.size >= 2
            entry[:edit_type] = :transfer
            entry[:balance_account_id] = info.min_by { |i| i[1] }[1]
          else
            entry[:balance_account_id] = info.first[1]
            entry[:edit_type] = info.first[2] == "debit" ? :deposit : :withdrawal
          end
        end
      end
    end

    # One account's display row — nil when it had no activity in the period.
    def account_row(account)
      data = @postings_data[account.id]
      return nil if data.nil? || data[:by_currency].empty?

      {
        id: account.id,
        code: account.code,
        name: account.name,
        account_type: account.account_type,
        entries: data[:entries],
        currency_totals: data[:by_currency],
        translated_total: data[:translated_total]
      }
    end
  end
end
