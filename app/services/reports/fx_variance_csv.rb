require "csv"

module Reports
  # The cross-currency transfers behind the "Exchange Rate Variance" line, one
  # row each. `rows` is ExchangeRate.fx_variance_rows; `total` their sum, which
  # is what the balance sheet, P&L and trial balance show on their single line.
  class FxVarianceCsv
    include CsvLabels

    # Rates are shown to 4 dp on screen (the transfer form, the warning) — the
    # export matches.
    RATE_PRECISION = 4

    def initialize(rows:, total:, display_currency:, start_date:, end_date:)
      @rows             = rows
      @total            = total
      @display_currency = display_currency
      @start_date       = start_date
      @end_date         = end_date
    end

    def generate
      CSV.generate(col_sep: CurrencyConfig.csv_separator) do |csv|
        csv << [csv_label(:report), shared_label("page.fx_variance")]
        if @start_date
          csv << [csv_label(:period), csv_label(:period_range, from: @start_date, to: @end_date)]
        else
          csv << [csv_label(:as_at), @end_date.to_s]
        end
        csv << [csv_label(:display_currency), @display_currency]
        csv << []

        csv << [
          shared_label("attrs.date"),
          shared_label("jargon.journal_entry"),
          shared_label("reports.fx_variance_page.leg_out"),
          shared_label("reports.fx_variance_page.leg_in"),
          shared_label("reports.fx_variance_page.implied_rate"),
          shared_label("reports.fx_variance_page.published_rate"),
          shared_label("reports.fx_translation_variance")
        ]

        @rows.each do |row|
          csv << [
            row[:entry_date].to_s,
            row[:memo],
            "#{CurrencyConfig.format_cents_csv(row[:from_amount_cents])} #{row[:from_currency]}",
            "#{CurrencyConfig.format_cents_csv(row[:to_amount_cents])} #{row[:to_currency]}",
            format_rate(row[:implied_rate]),
            format_rate(row[:published_rate]),
            CurrencyConfig.format_cents_csv(row[:variance_cents])
          ]
        end

        csv << []
        csv << ["", "", "", "", "",
                csv_label(:total_of, name: shared_label("reports.fx_translation_variance")),
                CurrencyConfig.format_cents_csv(@total)]
      end
    end

    private

    def format_rate(rate)
      rate.nil? ? "" : rate.round(RATE_PRECISION).to_s
    end
  end
end
