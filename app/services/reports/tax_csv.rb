# frozen_string_literal: true

require "csv"

module Reports
  # A tax-flavoured CSV: rows grouped by tax_category_key with per-section
  # totals and a NET row. Scheme-agnostic. Initialised from a Report for the
  # immediate download, or from explicit accounts + entity + date range for the
  # background export job.
  class TaxCsv
    include CsvLabels

    # `section` is a fixed three-value vocabulary enforced by TaxCategoryLoader,
    # so this file asks TaxCategory what a section means rather than keeping its
    # own copy.
    #
    # When it was free text this held word lists — %w[income einnahmen],
    # %w[expenses werbungskosten ausgaben] — and a country whose word was on
    # neither got every row and every subtotal falling through to "other", which
    # totals nothing: a NET line of zero, silently, into the submission archive
    # as well as this file.
    def initialize(accounts:, entity:, scheme:, start_date:, end_date:, display_currency:, admin:)
      @accounts         = accounts.to_a
      @entity           = entity
      @scheme           = scheme.to_s
      @start_date       = start_date
      @end_date         = end_date
      @display_currency = display_currency
      @admin            = admin
    end

    # Three buckets, not two. Anything that was not income falling into expenses
    # quietly made tax deducted at source an expense — and this feeds the
    # submission archive, the record of what was filed. A figure that is neither
    # now says so.
    def breakdown_data
      income_items  = []
      expense_items = []
      other_items   = []

      aggregated_by_category.each do |key, data|
        next if data[:section].blank?
        item = { key: key, label: data[:label], amount: data[:amount] }
        case data[:section]
        when TaxCategory::INCOME   then income_items  << item
        when TaxCategory::EXPENSES then expense_items << item
        else                                 other_items   << item
        end
      end

      [ income_items, expense_items, other_items ].each { |list| list.sort_by! { |i| i[:key] } }

      total_income   = income_items.sum  { |i| i[:amount] }
      total_expenses = expense_items.sum { |i| i[:amount] }

      {
        income:         income_items,
        expenses:       expense_items,
        other:          other_items,
        total_income:   total_income,
        total_expenses: total_expenses,
        net:            total_income - total_expenses
      }
    end

    def generate
      # Semicolon wherever the decimal separator is a comma, or the two collide
      # and the whole file lands in one column. See
      # CurrencyConfig.csv_separator.
      CSV.generate(col_sep: CurrencyConfig.csv_separator) do |csv|
        csv << [csv_label(:section), csv_label(:category_key), csv_label(:label), csv_label(:reference), csv_label(:amount, currency: @display_currency)]

        rows_by_section.each do |section, rows|
          rows.each { |row| csv << row }
          csv << [csv_label(:total_of, name: section).upcase, nil, nil, nil, section_total(section)]
          csv << []
        end

        csv << [csv_label(:net), nil, nil, nil, net_total]

        # Names what ACTUALLY answered, so a fallback shows up as two entries
        # rather than as one confident half-truth. These are the figures an
        # accountant carries onto a return, so the source line matters here most
        # of all.
        sources = rate_sources
        if sources.any?
          csv << []
          csv << [ csv_label(:rate_source), sources.join(", ") ]
        end
      end
    end

    private

    attr_reader :entity, :accounts, :scheme, :start_date, :end_date

    # Signed, translated totals by tax category — shared with the HMRC payload
    # so the CSV and the submission can never disagree (audit M9/R2).
    def category_totals
      @category_totals ||= Reports::TaxCategoryTotals.new(
        accounts: accounts, scheme: scheme, from: start_date, to: end_date,
        display_currency: @display_currency, entity: entity
      )
    end

    def aggregated_by_category
      @aggregated_by_category ||= category_totals.totals.transform_values do |d|
        { amount: d[:amount], section: d[:section], label: d[:label], ref: d[:export_column] }
      end
    end

    def rate_sources
      category_totals.rate_sources
    end

    def rows_by_section
      grouped = Hash.new { |h, k| h[k] = [] }
      aggregated_by_category.each do |key, data|
        next if data[:section].blank?
        grouped[data[:section]] << [
          data[:section], key, data[:label], data[:ref],
          CurrencyConfig.format_cents_csv(data[:amount])
        ]
      end
      grouped.each_value { |rows| rows.sort_by! { |r| r[1].to_s } }
      grouped
    end

    def section_total(section)
      amount = aggregated_by_category.values
                 .select { |d| d[:section] == section }
                 .sum { |d| d[:amount] }
      CurrencyConfig.format_cents_csv(amount)
    end

    def net_total
      income = aggregated_by_category.values
                 .select { |d| d[:section] == TaxCategory::INCOME }
                 .sum { |d| d[:amount] }
      expenses = aggregated_by_category.values
                   .select { |d| d[:section] == TaxCategory::EXPENSES }
                   .sum { |d| d[:amount] }

      CurrencyConfig.format_cents_csv(income - expenses)
    end

  end
end
