# frozen_string_literal: true

require "csv"

module Reports
  # The CSV of a saved TAX report — the same categorised figures the screen
  # shows, summary or detail per `short_version`. Summary is the box figures
  # (category and section totals + net); detail is the same plus every
  # transaction under its account.
  #
  # Both are built from one Reports::TaxReport instance, so the detail always
  # foots to the summary and both match what the submission carries.
  #
  # `receipts:` and `unlinked_receipts:` are passed only by the emailed export,
  # and only reach the detail form.
  class TaxReportCsv
    include CsvLabels

    def initialize(report:, data:, display_currency:, short_version:, receipts: nil, unlinked_receipts: nil)
      @report           = report
      @data             = data
      @display_currency = display_currency
      @short_version    = short_version
      @receipts         = receipts
      @unlinked         = unlinked_receipts
      @currencies       = data[:currencies].to_a
      @rate_gap         = data[:rate_unavailable]
      @translated       = @rate_gap.nil? &&
                          CurrencyColumns.translated?(@currencies, display_currency, forced: true)
      @receipts_col     = receipts && !short_version
    end

    def generate
      CSV.generate(col_sep: CurrencyConfig.csv_separator) do |csv|
        write_metadata(csv)
        csv << header_row

        last_section = nil
        (@data[:category_groups] || []).each do |cat|
          if cat[:section].present? && cat[:section] != last_section
            write_section_total(csv, last_section) if last_section
            csv << label_only_row(section_label(cat[:section]))
            last_section = cat[:section]
          end
          write_category(csv, cat)
        end
        write_section_total(csv, last_section) if last_section

        csv << []
        csv << total_row(csv_label(:net), @data.dig(:net, :currency_totals), @data.dig(:net, :translated_total))

        write_unlinked_receipts(csv) if @receipts_col && @unlinked.present?
      end
    end

    private

    def write_metadata(csv)
      csv << [ csv_label(:report), @report.report_group.display_name ]
      csv << [ csv_label(:period), csv_label(:period_range, from: @report.start_date, to: @report.end_date) ]
      csv << [ csv_label(:display_currency), @display_currency ]
      csv << [ csv_label(:form), @short_version ? csv_label(:form_summary) : csv_label(:form_detail) ]
      if @rate_gap
        csv << [ csv_label(:rate),
                 csv_label(:rate_unavailable, source: @rate_gap.source.to_s.upcase,
                           currency: @rate_gap.from_currency, date: @rate_gap.date) ]
      end
      sources = @data[:rate_sources].to_a
      csv << [ csv_label(:rate_source), sources.join(", ") ] if sources.any?
      csv << []
    end

    def header_row
      cells = [ shared_label("attrs.code") ]
      cells << shared_label("attrs.date") unless @short_version
      cells << I18n.t("reports.show.category")
      @currencies.each { |c| cells << c }
      cells << @display_currency if @translated
      cells << "ReceiptURL" if @receipts_col
      cells
    end

    def write_category(csv, cat)
      csv << label_only_row([ cat[:reference], cat[:label] ].compact.join(" — "))

      cat[:accounts].each do |account|
        next if account[:translated_total] == 0 && account[:currency_totals].values.all?(&:zero?)
        name = account_name(account)

        if @short_version
          csv << amount_row(account[:code], nil, name, account[:currency_totals], account[:translated_total])
        else
          csv << amount_row(account[:code], nil, name, {}, nil)
          (account[:entries] || []).each do |e|
            csv << amount_row(nil, e[:date], e[:description], { e[:currency] => e[:amount] }, e[:translated_amount],
                              receipt: receipt_links(e))
          end
          csv << amount_row(nil, nil, csv_label(:total_of, name: account[:name]),
                            account[:currency_totals], account[:translated_total])
        end
      end

      csv << amount_row(nil, nil, csv_label(:total_of, name: cat[:label]),
                        cat[:currency_totals], cat[:translated_total])
    end

    def write_section_total(csv, section)
      st = @data[:section_totals][section] or return
      csv << total_row(csv_label(:total_of, name: section_label(section)),
                       st[:currency_totals], st[:translated_total])
    end

    def write_unlinked_receipts(csv)
      csv << []
      csv << label_only_row(csv_label(:unlinked_receipts))
      @unlinked.each do |r|
        row = [ nil ]
        row << r[:date].to_s
        row << r[:title].to_s
        @currencies.each { row << nil }
        row << nil if @translated
        row << r[:url].to_s
        csv << row
      end
    end

    # --- row builders --------------------------------------------------

    def label_only_row(text)
      cells = [ nil ]
      cells << nil unless @short_version
      cells << text
      cells << nil if @receipts_col && !@short_version
      cells
    end

    def amount_row(code, date, label, currency_totals, translated_total, receipt: nil)
      cells = [ code ]
      cells << date&.to_s unless @short_version
      cells << label
      @currencies.each do |c|
        v = currency_totals[c]
        cells << (v && v != 0 ? CurrencyConfig.format_cents_csv(v) : nil)
      end
      cells << format_translated(translated_total) if @translated
      cells << receipt.presence if @receipts_col
      cells
    end

    def total_row(label, currency_totals, translated_total)
      amount_row(nil, nil, label, currency_totals || {}, translated_total)
    end

    def format_translated(value)
      value && value != 0 ? CurrencyConfig.format_cents_csv(value) : nil
    end

    def account_name(account)
      base = "#{account[:code]} - #{account[:name]}"
      account[:inactive] ? "#{base} (#{I18n.t('attrs.inactive')})" : base
    end

    def receipt_links(entry)
      Array(@receipts && @receipts[entry[:posting_id]]).join("\n")
    end

    def section_label(section)
      I18n.t("tax.section.#{section}")
    end
  end
end
