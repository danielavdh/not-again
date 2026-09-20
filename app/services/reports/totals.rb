# frozen_string_literal: true

module Reports
  # Translating a report's balances into one display currency and totalling
  # them. The three general reports — trial balance, profit and loss, balance
  # sheet — differ only in which buckets they sum; the translation itself lives
  # in Reports::Translation, shared with the custom report and the tax exports.
  #
  # Inputs are explicit arguments, not controller ivars — the whole reason this
  # is a class and not three eighty-line controller methods.
  class Totals
    # `sources:` is the series the reader chose in the converted-column
    # dropdown; nil lets tier 1 decide, which is every ordinary report.
    def initialize(display_currency:, currencies_with_data:, sources: nil)
      @display_currency     = display_currency
      @currencies_with_data = Array(currencies_with_data)
      @translation = Reports::Translation.new(
        display_currency: display_currency,
        sources:          sources,
        entity_id_for:    ->(account) { entity_id_for(account) }
      )
    end

    attr_reader :display_currency, :currencies_with_data

    # Which published series actually answered, in preference order. More than
    # one means a fallback fired — ESTV reaching back a month, the ECB covering
    # the rest — and the report must be able to say so.
    def rate_sources
      @translation.sources_used(currencies_with_data)
    end

    private

    # An account's entity is digits 2-3 of its code, so a CONSOLIDATED report
    # applies each business's own elected rate to its own accounts. Looked up
    # once for the whole report.
    def entity_id_for(account)
      @entity_ids_by_code ||= Entity.pluck(:code, :id).to_h
      @entity_ids_by_code[account.code[1, 2]]
    end

    # Sum an account's bucketed balances into the display currency, each bucket
    # at its own rate. `monthly` is { bucket_date => { currency => cents } }.
    def translate_monthly(monthly, account)
      @translation.translate_account(monthly, account)
    end

    # Same, but each bucket holds a { debit:, credit: } pair. Returns [debit,
    # credit].
    def translate_sides(monthly, account)
      @translation.translate_account_sides(monthly, account)
    end
  end
end
