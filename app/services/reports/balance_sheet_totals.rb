# frozen_string_literal: true

module Reports
  # A balance sheet: assets, liabilities and equity at a single date.
  #
  # ONE date, not one per month: a balance sheet is a position at a moment, so
  # every balance translates at the rate covering `as_of` — unlike the other two
  # reports, which sum activity across months and translate each at its own
  # rate.
  class BalanceSheetTotals < Totals
    def initialize(asset_accounts:, liability_accounts:, equity_accounts:,
                   balances_by_currency:, as_of:, **args)
      super(**args)
      @asset_accounts       = asset_accounts
      @liability_accounts   = liability_accounts
      @equity_accounts      = equity_accounts
      @balances_by_currency = balances_by_currency
      @as_of                = as_of
    end

    def call
      account_translated = {}

      assets,      translated_assets      = sum_group(@asset_accounts,     account_translated)
      liabilities, translated_liabilities = sum_group(@liability_accounts, account_translated)
      equity,      translated_equity      = sum_group(@equity_accounts,    account_translated)

      # Liabilities + equity, per currency and translated, and the net profit
      # that falls out of assets − (liabilities + equity). Figures on a
      # financial statement, so not the template's to compute.
      liability_equity = Hash.new(0)
      liabilities.each { |curr, amt| liability_equity[curr] += amt }
      equity.each      { |curr, amt| liability_equity[curr] += amt }
      translated_liability_equity = translated_liabilities + translated_equity

      [ account_translated, {
        asset_by_currency:            assets,
        liability_by_currency:        liabilities,
        equity_by_currency:           equity,
        liability_equity_by_currency: liability_equity,
        translated_assets:            translated_assets,
        translated_liabilities:       translated_liabilities,
        translated_equity:            translated_equity,
        translated_liability_equity:  translated_liability_equity,
        net_profit:                   translated_assets - translated_liability_equity
      } ]
    end

    private

    # Three groups, summed identically. A balance sheet is a position at ONE
    # date, so every balance translates at the rate covering as_of — modelled as
    # a single bucket dated as_of.
    def sum_group(accounts, account_translated)
      totals           = Hash.new(0)
      translated_group = 0

      accounts.each do |account|
        balances = @balances_by_currency[account.id] || {}
        balances.each { |curr, amt| totals[curr] += amt }

        translated = translate_monthly({ @as_of => balances }, account)
        account_translated[account.id] = translated
        translated_group += translated
      end

      [ totals, translated_group ]
    end
  end
end
