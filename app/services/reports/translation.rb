# frozen_string_literal: true

module Reports
  # Converts bucketed balances into one display currency — each bucket at its
  # own date's rate, each account at its own entity's elected rate where one
  # applies. The one place the rate policy lives; it was four copies before,
  # which is how the same books could translate differently on different
  # screens.
  #
  # sources:       the reader's dropdown choice, or nil to let tier 1 decide.
  # scheme:        set only for a tax report or filing — makes it use the
  # country's accepted series and date basis instead of tier 1.
  # entity_id_for: account_id → entity_id, so a consolidated report applies each
  # business's own rate to its own accounts.
  #
  # A missing rate raises ExchangeRate::RateUnavailable. The caller decides
  # whether that costs the converted column (the general reports) or is caught
  # and flagged (a custom report, which must keep its per-currency figures).
  class Translation
    def initialize(display_currency:, sources: nil, scheme: nil, entity_id_for: nil)
      @display_currency = display_currency
      @sources          = sources
      @scheme           = scheme
      @entity_id_for    = entity_id_for || ->(_) {}
      @translators      = {}
    end

    # by_bucket is { bucket_date => { currency => cents } } for ONE account.
    # Returns the sum in the display currency.
    def translate_account(by_bucket, account_id)
      entity_id = @entity_id_for.call(account_id)
      by_bucket.sum do |bucket_date, by_currency|
        by_currency.sum { |currency, cents| convert(cents, currency, bucket_date, entity_id) }
      end
    end

    # by_bucket where each value is { currency => { debit:, credit: } } — a
    # trial balance, whose two sides translate separately. Returns [debit,
    # credit].
    def translate_account_sides(by_bucket, account_id)
      entity_id = @entity_id_for.call(account_id)
      debit = 0
      credit = 0
      by_bucket.each do |bucket_date, by_currency|
        by_currency.each do |currency, sides|
          debit  += convert(sides[:debit],  currency, bucket_date, entity_id)
          credit += convert(sides[:credit], currency, bucket_date, entity_id)
        end
      end
      [ debit, credit ]
    end

    # One figure at one date — a custom-report line item.
    def translate_one(cents, currency, on:, account_id:)
      convert(cents, currency, on, @entity_id_for.call(account_id))
    end

    # Which published series actually answered, across these currencies.
    def sources_used(currencies)
      @translators.values.flat_map { |t| t.sources_used(currencies) }.uniq
    end

    private

    def convert(cents, currency, on, entity_id)
      return cents if currency == @display_currency
      return 0 if cents.nil? || cents.zero?
      translator_for(on).translate(cents, currency, on: on, entity_id: entity_id)
    end

    # One translator per month, reused — it covers that month's rates in one
    # query, and `on:` picks the day within it.
    def translator_for(date)
      @translators[date.to_date.beginning_of_month] ||=
        ExchangeRate.translator(@display_currency, date: date, scheme: @scheme, sources: @sources)
    end
  end
end
