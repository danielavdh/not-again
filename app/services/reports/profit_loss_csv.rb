require "csv"

module Reports
  # Generates a profit & loss CSV from pre-aggregated controller data.
  #
  # Mirrors Reports::TaxCsv shape. No Report record (ad-hoc by date
  # range + entity selection); takes the structured `data:` hash.
  #
  # Expected `data` keys:
  #   :income_accounts        Array<Account>
  #   :expense_accounts       Array<Account>
  #   :income_by_currency     { account_id => { currency => cents } }
  #   :expense_by_currency    { account_id => { currency => cents } }
  #   :account_translated     { account_id => cents }
  #   :totals                 { income_by_currency:, expense_by_currency:,
  #                             translated_income:, translated_expense: }
  #   :currencies_with_data   Array<String>
  class ProfitLossCsv
    include CsvLabels

    def initialize(data:, display_currency:, start_date:, end_date:, fx_variance: 0)
      @data             = data
      @display_currency = display_currency
      @start_date       = start_date
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
      # The translating column only when it converts something — see
      # Reports::CurrencyColumns.

      # A missing rate means @account_translated came back empty, so the
      # converted column would be 0.00 all the way down — an export that looks
      # complete and is not. Drop it, and say so in the header block, because a
      # CSV has no flash to explain itself.
      rate_gap = @data[:rate_unavailable]
      translated_col = rate_gap.nil? &&
                       CurrencyColumns.translated?(currencies_with_data, @display_currency)
      income_accounts      = @data[:income_accounts]
      expense_accounts     = @data[:expense_accounts]
      income_by_currency   = @data[:income_by_currency]
      expense_by_currency  = @data[:expense_by_currency]
      account_translated   = @data[:account_translated]
      totals               = @data[:totals]

      # Semicolon wherever the decimal separator is a comma, or the two collide
      # and the whole file lands in one column. See
      # CurrencyConfig.csv_separator.
      CSV.generate(col_sep: CurrencyConfig.csv_separator) do |csv|
        csv << [csv_label(:report), shared_label("page.profit_loss")]
        csv << [csv_label(:period), csv_label(:period_range, from: @start_date, to: @end_date)]
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
        currencies_with_data.each { |curr| headers << csv_label(:amount, currency: curr) }
        headers << csv_label(:amount, currency: @display_currency) if translated_col
        csv << headers

        # Income
        csv << ["", csv_label(:income_section)]
        income_accounts.each do |account|
          balances   = income_by_currency[account.id] || {}
          translated = account_translated[account.id] || 0
          row = [account.code, account.name]
          currencies_with_data.each do |curr|
            amt = balances[curr] || 0
            row << CurrencyConfig.format_cents_csv(amt)
          end
          row << CurrencyConfig.format_cents_csv(translated) if translated_col
          csv << row
        end

        income_row = ["", csv_label(:total_income)]
        currencies_with_data.each do |curr|
          income_row << CurrencyConfig.format_cents_csv(totals[:income_by_currency][curr])
        end
        income_row << CurrencyConfig.format_cents_csv(totals[:translated_income]) if translated_col
        csv << income_row

        csv << []

        # Expenses
        csv << ["", csv_label(:expenses_section)]
        expense_accounts.each do |account|
          balances   = expense_by_currency[account.id] || {}
          translated = account_translated[account.id] || 0
          row = [account.code, account.name]
          currencies_with_data.each do |curr|
            amt = balances[curr] || 0
            row << CurrencyConfig.format_cents_csv(amt)
          end
          row << CurrencyConfig.format_cents_csv(translated) if translated_col
          csv << row
        end

        expense_row = ["", csv_label(:total_expenses)]
        currencies_with_data.each do |curr|
          expense_row << CurrencyConfig.format_cents_csv(totals[:expense_by_currency][curr])
        end
        expense_row << CurrencyConfig.format_cents_csv(totals[:translated_expense]) if translated_col
        csv << expense_row

        csv << []

        # Net
        net_row = ["", csv_label(:net_profit_loss)]
        currencies_with_data.each do |curr|
          net = totals[:income_by_currency][curr] - totals[:expense_by_currency][curr]
          net_row << CurrencyConfig.format_cents_csv(net)
        end
        net_profit = totals[:translated_income] - totals[:translated_expense]
        net_row << CurrencyConfig.format_cents_csv(net_profit) if translated_col
        csv << net_row

        # FX variance + adjusted net
        if @fx_variance && @fx_variance != 0
          csv << ["", shared_label("reports.fx_translation_variance"), *([""] * currencies_with_data.size), CurrencyConfig.format_cents_csv(@fx_variance)]
          adjusted = net_profit + @fx_variance
          csv << ["", shared_label("reports.net_profit_loss_adjusted"), *([""] * currencies_with_data.size), CurrencyConfig.format_cents_csv(adjusted)]
        end
      end
    end
  end
end