require "csv"

module Reports
  # The "standard" custom report CSV, long or short form, from the structured
  # @data hash Reports::CustomReport produces.
  #
  # `receipts:` ({ posting_id => [url] }) and `unlinked_receipts:` are passed
  # only by the emailed export — they add a ReceiptURL column to the detail form
  # and an unlinked-receipts section, so the accountant gets the document links
  # alongside the figures. On-demand downloads pass neither.
  class StandardCsv
    include CsvLabels

    def initialize(report:, data:, display_currency:, short_version:, receipts: nil, unlinked_receipts: nil)
      @report           = report
      @data             = data
      @display_currency = display_currency
      @short_version    = short_version
      @receipts         = receipts
      @unlinked         = unlinked_receipts
    end

    def generate
      currencies_with_data = @data[:currencies]

      # A missing rate means every translated figure came back as 0, so this
      # column would read 0.00 all the way down — an export that looks complete
      # and is not. CustomReport reports the gap through the same data hash;
      # here it costs the column.
      rate_gap = @data[:rate_unavailable]

      # Same rule as the on-screen report: the translating column earns its
      # place only when it says something the per-currency columns do not.
      translated = rate_gap.nil? &&
                   (currencies_with_data.blank? ||
                    currencies_with_data.size > 1 ||
                    currencies_with_data.first != @display_currency)

      # The ReceiptURL column exists only in the emailed detail form.
      receipts_col = @receipts && !@short_version

      CSV.generate(col_sep: CurrencyConfig.csv_separator) do |csv|
        if rate_gap
          csv << [ csv_label(:rate),
                   csv_label(:rate_unavailable,
                             source: rate_gap.source.to_s.upcase,
                             currency: rate_gap.from_currency,
                             date: rate_gap.date) ]
          csv << []
        end

        sources = @data[:rate_sources].to_a
        if sources.any?
          csv << [ csv_label(:rate_source), sources.join(", ") ]
          csv << []
        end

        if @short_version
          csv << [ shared_label("attrs.code"), shared_label("jargon.account"), *currencies_with_data, *(translated ? [ @display_currency ] : []) ]
        else
          csv << [ shared_label("attrs.code"), shared_label("attrs.date"), shared_label("jargon.account"), *currencies_with_data, *(translated ? [ @display_currency ] : []), *(receipts_col ? [ "ReceiptURL" ] : []) ]
        end

        last_type = nil

        (@data[:parent_groups] || []).each do |parent_group|
          current_type = parent_group[:accounts].first[:account_type] rescue nil

          if @data[:show_type_totals] && current_type != last_type
            if last_type && @data[:type_totals][last_type]
              tt = @data[:type_totals][last_type]
              if @short_version
                csv << [ "", csv_label(:total_of, name: last_type.humanize),
                  *currencies_with_data.map { |c| CurrencyConfig.format_cents_csv(tt[:currency_totals][c]) },
                  *(translated ? [ CurrencyConfig.format_cents_csv(tt[:translated_total]) ] : [])
                ]
              else
                csv << [ "", "", csv_label(:total_of, name: shared_label("jargon.#{last_type}")),
                  *currencies_with_data.map { |c| CurrencyConfig.format_cents_csv(tt[:currency_totals][c]) },
                  *(translated ? [ CurrencyConfig.format_cents_csv(tt[:translated_total]) ] : []),
                  *(receipts_col ? [ "" ] : [])
                ]
              end
              csv << []
            end

            if @short_version
              csv << [ "", shared_label("jargon.#{current_type}") ]
            else
              csv << [ "", "", shared_label("jargon.#{current_type}") ]
            end
            last_type = current_type
          end

          parent_group[:accounts].each do |account|
            next if account[:translated_total] == 0 && account[:currency_totals].values.all?(&:zero?)

            if @short_version
              csv << [
                account[:code],
                account[:name],
                *currencies_with_data.map { |c| CurrencyConfig.format_cents_csv(account[:currency_totals][c]) },
                *(translated ? [ CurrencyConfig.format_cents_csv(account[:translated_total]) ] : [])
              ]
            else
              csv << [ account[:code], "", account[:name], *([ "" ] * currencies_with_data.size), *(translated ? [ "" ] : []), *(receipts_col ? [ "" ] : []) ]

              (account[:entries] || []).each do |entry|
                csv << [
                  "",
                  entry[:date],
                  entry[:description],
                  *currencies_with_data.map { |c| entry[:currency] == c ? CurrencyConfig.format_cents_csv(entry[:amount]) : "" },
                  *(translated ? [ CurrencyConfig.format_cents_csv(entry[:translated_amount]) ] : []),
                  *(receipts_col ? [ receipt_links(entry) ] : [])
                ]
              end

              csv << [
                "",
                "",
                csv_label(:total_of, name: account[:name]),
                *currencies_with_data.map { |c| CurrencyConfig.format_cents_csv(account[:currency_totals][c]) },
                *(translated ? [ CurrencyConfig.format_cents_csv(account[:translated_total]) ] : []),
                *(receipts_col ? [ "" ] : [])
              ]
            end
          end

          if parent_group[:accounts].size > 1
            if @short_version
              csv << [
                parent_group[:parent_code],
                csv_label(:total_of, name: parent_group[:total_name]),
                *currencies_with_data.map { |c| CurrencyConfig.format_cents_csv(parent_group[:currency_totals][c]) },
                *(translated ? [ CurrencyConfig.format_cents_csv(parent_group[:translated_total]) ] : [])
              ]
            else
              csv << [
                parent_group[:parent_code],
                "",
                csv_label(:total_of, name: parent_group[:total_name]),
                *currencies_with_data.map { |c| CurrencyConfig.format_cents_csv(parent_group[:currency_totals][c]) },
                *(translated ? [ CurrencyConfig.format_cents_csv(parent_group[:translated_total]) ] : []),
                *(receipts_col ? [ "" ] : [])
              ]
            end
          end
        end

        if @data[:show_type_totals] && last_type && @data[:type_totals][last_type]
          tt = @data[:type_totals][last_type]
          if @short_version
            csv << [ "", csv_label(:total_of, name: shared_label("jargon.#{last_type}")),
              *currencies_with_data.map { |c| CurrencyConfig.format_cents_csv(tt[:currency_totals][c]) },
              *(translated ? [ CurrencyConfig.format_cents_csv(tt[:translated_total]) ] : [])
            ]
          else
            csv << [ "", "", csv_label(:total_of, name: shared_label("jargon.#{last_type}")),
              *currencies_with_data.map { |c| CurrencyConfig.format_cents_csv(tt[:currency_totals][c]) },
              *(translated ? [ CurrencyConfig.format_cents_csv(tt[:translated_total]) ] : []),
              *(receipts_col ? [ "" ] : [])
            ]
          end
        end

        write_unlinked_receipts(csv, currencies_with_data, translated) if receipts_col && @unlinked.present?
      end
    end

    private

    def receipt_links(entry)
      Array(@receipts && @receipts[entry[:posting_id]]).join("\n")
    end

    def write_unlinked_receipts(csv, currencies_with_data, translated)
      csv << []
      csv << [ "", "", csv_label(:unlinked_receipts) ]
      @unlinked.each do |r|
        csv << [ "", r[:date].to_s, r[:title].to_s,
                 *([ "" ] * currencies_with_data.size), *(translated ? [ "" ] : []), r[:url].to_s ]
      end
    end
  end
end
