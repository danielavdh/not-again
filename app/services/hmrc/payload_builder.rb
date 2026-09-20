# frozen_string_literal: true

module Hmrc
  # Builds the quarterly update payload for the HMRC MTD API, from the same
  # inputs as TaxCsv — accounts, entity and date range.
  #
  # payload = PayloadBuilder.new(entity: entity, accounts: accounts,
  # start_date: date, end_date: date,
  # scheme: :gb_self_employment).build
  class PayloadBuilder
    def initialize(entity:, accounts:, start_date:, end_date:, scheme:, display_currency: "GBP")
      @entity           = entity
      @accounts         = accounts
      @start_date       = start_date.to_date
      @end_date         = end_date.to_date
      @scheme           = scheme.to_s
      @display_currency = display_currency
    end

    # Scheme slugs are ours, as stored on accounts and catalogue rows — not
    # HMRC's endpoint naming. "property" is accepted for callers that still pass
    # HMRC's name, but it selects no accounts, so it is not a valid input.
    def build
      case @scheme
      when "gb_self_employment" then build_self_employment
      when "gb_property"        then build_property
      else raise "Unknown scheme: #{@scheme}"
      end
    end

    private

    # Self Employment Business API payload structure
    def build_self_employment
      income   = {}
      expenses = {}

      category_totals.each do |key, data|
        # The authority field name now travels on the category row itself,
        # so there is no second file that can silently omit a category.
        api_field = data[:api_field]
        next if api_field.blank?

        amount = (data[:amount] / 100.0).round(2)
        next if amount.zero?

        # payload_section, not section: HMRC files tax deducted at source inside
        # the income object although it is not income. section keeps that figure
        # out of the report's income total; this puts it in the right half of
        # the payload.
        if data[:payload_section] == TaxCategory::INCOME
          income[api_field]   = amount
        else
          expenses[api_field] = amount
        end
      end

      payload = {
        periodDates: {
          periodStartDate: @start_date.to_s,
          periodEndDate:   @end_date.to_s
        }
      }
      payload[:periodIncome]   = income   if income.any?
      payload[:periodExpenses] = expenses if expenses.any?

      # A period with no activity is still an obligation. HMRC requires an
      # explicit "nil update" and rejects a body carrying no financial data, so
      # send a zero turnover — a valid nil return rather than an empty body.
      if !payload.key?(:periodIncome) && !payload.key?(:periodExpenses)
        payload[:periodIncome] = { turnover: 0.0 }
      end

      payload
    end

    # UK Property Business API payload structure. Income and expenses are flat
    # field → amount pairs inside a wrapper whose key depends on the tax year:
    # the cumulative model (2025-26+) uses "ukProperty", the legacy per-period
    # endpoint "ukNonFhlProperty".
    def build_property
      income   = {}
      expenses = {}

      category_totals.each do |key, data|
        # The authority field name now travels on the category row itself,
        # so there is no second file that can silently omit a category.
        api_field = data[:api_field]
        next if api_field.blank?

        amount = (data[:amount] / 100.0).round(2)
        next if amount.zero?

        # payload_section, not section: HMRC files tax deducted at source inside
        # the income object although it is not income. section keeps that figure
        # out of the report's income total; this puts it in the right half of
        # the payload.
        if data[:payload_section] == TaxCategory::INCOME
          income[api_field]   = amount
        else
          expenses[api_field] = amount
        end
      end

      inner = {}
      inner[:income]   = income   if income.any?
      inner[:expenses] = expenses if expenses.any?

      # A period with no activity is still an obligation, and HMRC rejects an
      # empty body, so send a zero rent as an explicit nil update.
      inner[:income] = { periodAmount: 0.0 } if inner.empty?

      {
        fromDate:               @start_date.to_s,
        toDate:                 @end_date.to_s,
        property_wrapper_key => inner
      }
    end

    # FHL was abolished from 2025-26: the cumulative property API expects the
    # "ukProperty" wrapper and rejects "ukNonFhlProperty"; the legacy per-period
    # endpoint is the reverse. Keyed off the submission start date.
    def property_wrapper_key
      TaxYear.cumulative?(@start_date) ? :ukProperty : :ukNonFhlProperty
    end

    # Signed, translated totals by tax category — the SAME service the tax-CSV
    # breakdown reads, so the figure filed here and the figure in the archived
    # copy of this submission can never diverge.
    def category_totals
      @category_totals ||= Reports::TaxCategoryTotals.new(
        accounts: @accounts, scheme: @scheme, from: @start_date, to: @end_date,
        display_currency: @display_currency, entity: @entity
      ).totals
    end

  end
end
