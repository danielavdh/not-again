require "csv"

module Reports
  # Generates a trial balance CSV from pre-aggregated controller data.
  #
  # Mirrors Reports::TaxCsv shape. There's no Report record here
  # (trial balance is ad-hoc by date + entity selection), so the input
  # is the structured `data:` hash the controller already builds.
  #
  # Expected `data` keys:
  #   :accounts                  Array<Account>
  #   :balances_by_currency      { account_id => { currency => { debit:, credit:
  # } } }
  #   :account_translated        { account_id => { debit:, credit: } }
  #   :totals                    { debit_by_currency:, credit_by_currency:,
  #                                translated_debit:, translated_credit: }
  #   :currencies_with_data      Array<String>
  class TrialBalanceCsv
    include CsvLabels

    def initialize(data:, display_currency:, end_date:, fx_variance: 0)
      @data             = data
      @display_currency = display_currency
      @end_date         = end_date
      @fx_variance      = fx_variance
    end

    def generate
      # What ACTUALLY answered, from the translators that did the work — never
      # derived. Empty means the line is omitted entirely and the UNAVAILABLE
      # line below says why: printing a derived source when nothing answered
      # produced a file with an empty converted column naming a source that was
      # never consulted.
      source = @data[:rate_sources].to_a.join(", ").presence
      currencies_with_data = @data[:currencies_with_data]
      # The translating PAIR (debit + credit) only when it converts something
      # — see Reports::CurrencyColumns.

      # A missing rate means @account_translated came back empty, so the
      # converted column would be 0.00 all the way down — an export that looks
      # complete and is not. Drop it, and say so in the header block, because a
      # CSV has no flash to explain itself.
      rate_gap = @data[:rate_unavailable]
      translated_col = rate_gap.nil? &&
                       CurrencyColumns.translated?(currencies_with_data, @display_currency)
      accounts             = @data[:accounts]
      balances_by_currency = @data[:balances_by_currency]
      account_translated   = @data[:account_translated]
      totals               = @data[:totals]

      # Semicolon wherever the decimal separator is a comma, or the two collide
      # and the whole file lands in one column. See
      # CurrencyConfig.csv_separator.
      CSV.generate(col_sep: CurrencyConfig.csv_separator) do |csv|
        # Metadata
        csv << [csv_label(:report), shared_label("page.trial_balance")]
        csv << [csv_label(:as_at), @end_date.to_s]
        csv << [csv_label(:display_currency), @display_currency]
        csv << [csv_label(:rate_source), source] if source
        if rate_gap
          csv << [ csv_label(:rate),
                   csv_label(:rate_unavailable,
                             source: rate_gap.source.to_s.upcase,
                             currency: rate_gap.from_currency,
                             date: rate_gap.date) ]
        end
        csv << []

        # Column headers
        headers = [shared_label("attrs.code"), shared_label("jargon.account")]
        currencies_with_data.each do |curr|
          headers << csv_label(:debit, currency: curr)
          headers << csv_label(:credit, currency: curr)
        end
        headers << csv_label(:debit, currency: @display_currency) << csv_label(:credit, currency: @display_currency) if translated_col
        csv << headers

        accounts.each do |account|
          balances = balances_by_currency[account.id] || {}
          next if balances.empty?

          translated = account_translated[account.id] || { debit: 0, credit: 0 }
          row = [account.code, account.name]

          currencies_with_data.each do |curr|
            d = balances[curr] || { debit: 0, credit: 0 }
            row << CurrencyConfig.format_cents_csv(d[:debit])
            row << CurrencyConfig.format_cents_csv(d[:credit])
          end

          if translated_col
            row << CurrencyConfig.format_cents_csv(translated[:debit])
            row << CurrencyConfig.format_cents_csv(translated[:credit])
          end
          csv << row
        end

        # Totals row
        totals_row = ["", csv_label(:totals)]
        currencies_with_data.each do |curr|
          totals_row << CurrencyConfig.format_cents_csv(totals[:debit_by_currency][curr] )
          totals_row << CurrencyConfig.format_cents_csv(totals[:credit_by_currency][curr])
        end
        if translated_col
          totals_row << CurrencyConfig.format_cents_csv(totals[:translated_debit] )
          totals_row << CurrencyConfig.format_cents_csv(totals[:translated_credit])
        end
        csv << totals_row

        # FX variance + adjusted totals
        if @fx_variance && @fx_variance != 0
          fx_row = ["", shared_label("reports.fx_translation_variance")]
          currencies_with_data.each { fx_row << "" << "" }
          if @fx_variance > 0
            fx_row << "" << CurrencyConfig.format_cents_csv(@fx_variance)
          else
            fx_row << CurrencyConfig.format_cents_csv(@fx_variance.abs) << ""
          end
          csv << fx_row

          adj_row = ["", shared_label("reports.adjusted_totals")]
          currencies_with_data.each { adj_row << "" << "" }
          adjusted_debit  = totals[:translated_debit]  + (@fx_variance < 0 ? @fx_variance.abs : 0)
          adjusted_credit = totals[:translated_credit] + (@fx_variance > 0 ? @fx_variance     : 0)
          adj_row << CurrencyConfig.format_cents_csv(adjusted_debit )
          adj_row << CurrencyConfig.format_cents_csv(adjusted_credit)
          csv << adj_row
        end
      end
    end
  end
end