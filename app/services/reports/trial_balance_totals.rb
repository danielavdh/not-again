# frozen_string_literal: true

module Reports
  # A trial balance: every account's debits and credits, per currency and
  # translated.
  class TrialBalanceTotals < Totals
    def initialize(accounts:, balances_by_currency:, balances_by_month:, **args)
      super(**args)
      @accounts             = accounts
      @balances_by_currency = balances_by_currency
      @balances_by_month    = balances_by_month
    end

    # [account_translated, totals] — the shape the views and the CSV exporter
    # already expect, kept exactly.
    def call
      account_translated = {}
      debit_totals       = Hash.new(0)
      credit_totals      = Hash.new(0)
      translated_debit   = 0
      translated_credit  = 0

      @accounts.each do |account|
        balances = @balances_by_currency[account.id] || {}
        next if balances.empty?

        currencies_with_data.each do |curr|
          data = balances[curr] || { debit: 0, credit: 0 }
          debit_totals[curr]  += data[:debit]
          credit_totals[curr] += data[:credit]
        end

        account_debit, account_credit = translate_sides(@balances_by_month[account.id] || {}, account)

        account_translated[account.id] = { debit: account_debit, credit: account_credit }
        translated_debit  += account_debit
        translated_credit += account_credit
      end

      [ account_translated, {
        debit_by_currency:  debit_totals,
        credit_by_currency: credit_totals,
        translated_debit:   translated_debit,
        translated_credit:  translated_credit
      } ]
    end
  end
end
