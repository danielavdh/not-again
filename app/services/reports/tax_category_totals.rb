# frozen_string_literal: true

module Reports
  # Signed, translated totals grouped by TAX CATEGORY, for one scheme over one
  # period. The shared core of the tax CSV and the HMRC payload: aggregating and
  # translating separately meant the CSV passed the scheme's accepted rate
  # source while the payload did not, so the figure FILED and the figure
  # ARCHIVED would diverge the day books are kept in another currency.
  #
  # totals → { category_key => {
  # amount:,          # signed cents, translated to display_currency
  # section:,         # TaxCategory::INCOME / EXPENSES / OTHER
  # label:, export_column:,          # for the CSV
  # api_field:, payload_section: } } # for the HMRC payload
  class TaxCategoryTotals
    def initialize(accounts:, scheme:, from:, to:, display_currency:, entity:)
      @accounts         = accounts.to_a
      @scheme           = scheme.to_s
      @from             = from.to_date
      @to               = to.to_date
      @display_currency = display_currency
      @entity           = entity
    end

    def totals
      @totals ||= build
    end

    # Which published series actually answered — a fallback shows as two.
    def rate_sources
      totals # ensure the translation ran
      @translation ? @translation.sources_used(@currencies || []) : []
    end

    private

    def build
      scheme_accounts = @accounts.select { |a| a.tax_scheme == @scheme }
      return {} if scheme_accounts.empty?

      key_of     = scheme_accounts.to_h { |a| [ a.id, a.tax_category_key.presence ] }
      categories = load_categories(key_of.values.compact.uniq)
      return {} if categories.empty?

      @translation = Reports::Translation.new(
        display_currency: @display_currency,
        scheme:           @scheme,
        entity_id_for:    ->(_) { @entity&.id }
      )

      by_bucket = Reports::LedgerBalances.new(
        accounts: scheme_accounts, from: @from, to: @to,
        bucket: bucket, include_closing: false
      ).call

      @currencies = by_bucket.values.flat_map { |b| b.values.flat_map(&:keys) }.uniq

      out = Hash.new { |h, k| h[k] = { amount: 0 } }
      by_bucket.each do |account_id, buckets|
        key = key_of[account_id]
        cat = key && categories[key]
        next unless cat

        out[key][:amount]         += @translation.translate_account(buckets, account_id)
        out[key][:section]        ||= cat.section
        out[key][:label]          ||= cat.label
        out[key][:export_column]  ||= cat.export_column
        out[key][:api_field]      ||= cat.api_field
        out[key][:payload_section] ||= cat.payload_section
      end
      out
    end

    # Day-grouping only when the scheme's accepted source publishes daily —
    # otherwise a month covers every day at one rate and the extra rows are
    # wasted.
    def bucket
      source = ExchangeRate.sources_for_scheme(@scheme)&.first
      RateSourceConfig.daily?(source) ? :day : :month
    end

    # The catalogue as it stood for the period being reported — the year from
    # the period's end date, counted the way the scheme's country counts it.
    def load_categories(keys)
      return {} if keys.empty?

      TaxCategory.for_period(
        scheme: @scheme,
        keys:   keys,
        year:   TaxCategory.tax_year_for(
                  country_code: TaxSchemeConfig.country_for(@scheme),
                  date:         @to
                )
      )
    end
  end
end
