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
                             source: RateSourceConfig.label_for(rate_gap.source),
                             currency: rate_gap.from_currency,
                             date: rate_gap.date) ]
          csv << []
        end

        total_col = translated ? [ csv_label(:total_of, name: @display_currency) ] : []
        header = if @short_version
          [ shared_label("attrs.code"), shared_label("jargon.account"), *currencies_with_data, *total_col ]
        else
          [ shared_label("attrs.code"), shared_label("attrs.date"), shared_label("jargon.account"), *currencies_with_data, *total_col, *(receipts_col ? [ "ReceiptURL" ] : []) ]
        end

        write_provenance(csv, translated, header.size)
        csv << header

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

    # Whose books, what period, and what the last column is. The file travels on
    # its own — an accountant opening the attachment has only what is inside it,
    # and the period used to live in the filename alone.
    def write_provenance(csv, translated, width)
      rows = []
      if @report
        rows << [ csv_label(:report), @report.report_group.display_name ]
        rows << [ csv_label(:period),
                  csv_label(:period_range, from: @report.start_date, to: @report.end_date) ]
      end

      sources = @data[:rate_sources].to_a.map { |src| RateSourceConfig.label_for(src) }
      rows << [ csv_label(:rate_source), sources.join(", ") ] if sources.any?

      if translated && sources.any?
        rows << [ csv_label(:display_currency), @display_currency ]
        rows << [ "", csv_label(:total_explained, currency: @display_currency,
                                source: sources.join(", ")) ]
      end

      return if rows.empty?

      # A spreadsheet treats row 1 as the header row and styles it, which lands
      # on the provenance rather than on the real header further down. Naming
      # the last column there too means the sticky header still says what the
      # right-hand figures are.
      if translated
        rows.first[width - 1] = csv_label(:total_of, name: @display_currency).upcase if width > rows.first.size
      end

      rows.each { |row| csv << row }
      csv << []
    end

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
