# frozen_string_literal: true

require "csv"

module Reports
  # The VAT return as a file: the boxes of the form first, because that is what
  # gets copied onto it, then the per-code detail the figures came from.
  #
  # Fixed shape and locale-independent column ORDER, per the V2 rule — the
  # headings translate, the columns never move.
  class VatReturnCsv
    include CsvLabels

    def initialize(data:)
      @data = data
    end

    def generate
      CSV.generate(col_sep: CurrencyConfig.csv_separator) do |csv|
        csv << [ @data[:scheme_label], @data[:entity].name,
                 I18n.l(@data[:from], format: :short_date),
                 I18n.l(@data[:to], format: :short_date),
                 @data[:currency] ]
        csv << []

        csv << [ shared_label("tax.vat.boxes") ]
        csv << [ shared_label("tax.vat.box"), shared_label("attrs.description"),
                 @data[:flat_rate_bps] ?
                   "#{@data[:flat_rate_label]} (#{@data[:flat_rate_bps] / 100.0}%)" :
                   csv_label(:total_of, name: @data[:currency]),
                 (@data[:normal_rules_label] if @data[:comparison_boxes].any?) ].compact
        comparison = @data[:comparison_boxes].index_by(&:key)
        @data[:boxes].each do |box|
          row = [ box.reference, box.label, money(box.amount) ]
          # Appended, never substituted: column 3 is always what gets filed.
          row << money(comparison[box.key]&.amount.to_i) if comparison.any?
          csv << row
        end
        csv << []

        csv << [ shared_label("tax.vat.summary") ]
        csv << [ shared_label("tax.vat.due"),       money(@data[:vat_due]) ]
        csv << [ shared_label("tax.vat.reclaimed"), money(@data[:vat_reclaimed]) ]
        csv << [ shared_label("tax.vat.payable"),   money(@data[:net_payable]) ]
        # Only when there is something to say: VAT in the control accounts that
        # no code put there, so the boxes above are short by it.
        unless @data[:unassigned].zero?
          csv << [ shared_label("tax.vat.unassigned"), money(@data[:unassigned]) ]
        end
        csv << []

        csv << [ shared_label("tax.vat.by_code") ]
        csv << [ shared_label("tax.vat.direction_label"), shared_label("tax.vat.code"),
                 shared_label("attrs.rate"),
                 shared_label("tax.vat.net"), shared_label("tax.vat.amount"),
                 shared_label("tax.vat.reverse_charge") ]
        @data[:lines].each do |line|
          csv << [ shared_label("tax.vat.direction_short.#{line.code.direction}"),
                   line.code.label, line.code.rate_label,
                   money(line.net), money(line.tax),
                   line.code.reverse_charge? ? money(line.reverse_tax) : nil ]
        end

        # Per account as well, because this is the half an accountant reads.
        if @data[:account_lines].any?
          csv << []
          csv << [ shared_label("tax.vat.by_account") ]
          csv << [ shared_label("jargon.account"), shared_label("tax.vat.code"),
                   shared_label("attrs.rate"),
                   shared_label("tax.vat.net"), shared_label("tax.vat.amount") ]
          @data[:account_lines].each do |line|
            csv << [ "#{line.account_code} - #{line.account_name}",
                     line.code.label, line.code.rate_label,
                     money(line.net), money(line.tax) ]
          end
        end
      end
    end

    private

    def money(cents)
      CurrencyConfig.format_display(cents / 100.0)
    end
  end
end
