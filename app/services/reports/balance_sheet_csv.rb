require "csv"

module Reports
  # Generates a balance sheet CSV from pre-aggregated controller data.
  #
  # Expected `data` keys:
  #   :asset_accounts        Array<Account>
  #   :liability_accounts    Array<Account>
  #   :equity_accounts       Array<Account>
  #   :balances_by_currency  { account_id => { currency => cents } }
  #   :account_translated    { account_id => cents }
  #   :totals                { asset_by_currency:, liability_by_currency:,
  # equity_by_currency:,
  #                            translated_assets:, translated_liabilities:,
  # translated_equity: }
  #   :currencies_with_data  Array<String>
  class BalanceSheetCsv
    include CsvLabels

    def initialize(data:, display_currency:, end_date:)
      @data             = data
      @display_currency = display_currency
      @end_date         = end_date
      @fx_variance      = data[:fx_variance].to_i
    end

    def generate
      # What ACTUALLY answered, from the translators that did the work — never
      # derived. Empty means the line is omitted entirely and the UNAVAILABLE
      # line below says why: printing a derived source when nothing answered
      # produced a file with an empty converted column naming a source that was
      # never consulted.
      source = @data[:rate_sources].to_a.join(", ").presence
      currencies_with_data = @data[:currencies_with_data]
      # The translating column only when it converts something — see
      # Reports::CurrencyColumns.

      # A missing rate means @account_translated came back empty, so the
      # converted column would be 0.00 all the way down — an export that looks
      # complete and is not. Drop it, and say so in the header block, because a
      # CSV has no flash to explain itself.
      rate_gap = @data[:rate_unavailable]
      translated_col = rate_gap.nil? &&
                       CurrencyColumns.translated?(currencies_with_data, @display_currency)
      totals               = @data[:totals]

      # Semicolon wherever the decimal separator is a comma, or the two collide
      # and the whole file lands in one column. See
      # CurrencyConfig.csv_separator.
      CSV.generate(col_sep: CurrencyConfig.csv_separator) do |csv|
        csv << [csv_label(:report), shared_label("page.balance_sheet")]
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

        headers = [shared_label("attrs.code"), shared_label("jargon.account")]
        currencies_with_data.each { |curr| headers << curr }
        headers << @display_currency if translated_col
        csv << headers

        {
          assets:      [:asset_accounts,     :asset_by_currency,     :translated_assets],
          liabilities: [:liability_accounts, :liability_by_currency, :translated_liabilities],
          equity:      [:equity_accounts,    :equity_by_currency,    :translated_equity]
        }.each do |label, (accounts_key, currency_totals_key, translated_key)|
          accounts = @data[accounts_key]
          next if accounts.empty?

          csv << ["", csv_label(:"#{label}_section")]

          accounts.each do |account|
            balances   = @data[:balances_by_currency][account.id] || {}
            translated = @data[:account_translated][account.id] || 0
            row = [account.code, account.name]
            currencies_with_data.each { |curr| row << CurrencyConfig.format_cents_csv(balances[curr]) }
            row << CurrencyConfig.format_cents_csv(translated) if translated_col
            csv << row
          end

          total_row = ["", csv_label(:total_of, name: csv_label(label))]
          currencies_with_data.each { |curr| total_row << CurrencyConfig.format_cents_csv(totals[currency_totals_key][curr]) }
          total_row << CurrencyConfig.format_cents_csv(totals[translated_key]) if translated_col
          csv << total_row
          csv << []
        end

        le_total = totals[:translated_liabilities] + totals[:translated_equity]
        check_row = ["", csv_label(:total_liabilities_equity)]
        currencies_with_data.each do |curr|
          check_row << CurrencyConfig.format_cents_csv(totals[:liability_by_currency][curr] + totals[:equity_by_currency][curr])
        end
        check_row << CurrencyConfig.format_cents_csv(le_total) if translated_col
        csv << check_row

        # The residual, split: unclosed profit and, on its own line, the FX
        # translation variance from cross-currency transfers.
        if translated_col
          residual = totals[:translated_assets] - le_total
          blanks   = [""] * currencies_with_data.size
          csv << ["", shared_label("reports.balance_sheet.net_profit_loss"), *blanks, CurrencyConfig.format_cents_csv(residual)]
          if @fx_variance != 0
            csv << ["", shared_label("reports.fx_translation_variance"), *blanks, CurrencyConfig.format_cents_csv(@fx_variance)]
            csv << ["", shared_label("reports.balance_sheet.net_profit_loss_excl_fx"), *blanks, CurrencyConfig.format_cents_csv(residual - @fx_variance)]
          end
        end

        balanced = totals[:translated_assets] == le_total
        csv << ["", balanced ? csv_label(:balanced) : csv_label(:not_balanced, difference: "#{CurrencyConfig.format_cents_csv((totals[:translated_assets] - le_total).abs)} #{@display_currency}")]
      end
    end
  end
end
