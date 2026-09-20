# frozen_string_literal: true

module Reports
  # A profit and loss: income and expenditure, per currency and translated, with
  # the bottom line.
  class ProfitLossTotals < Totals
    def initialize(income_accounts:, expense_accounts:, income_by_currency:,
                   expense_by_currency:, balances_by_month:, **args)
      super(**args)
      @income_accounts     = income_accounts
      @expense_accounts    = expense_accounts
      @income_by_currency  = income_by_currency
      @expense_by_currency = expense_by_currency
      @balances_by_month   = balances_by_month
    end

    def call
      account_translated = {}

      income_totals, translated_income =
        sum_side(@income_accounts, @income_by_currency, account_translated)
      expense_totals, translated_expense =
        sum_side(@expense_accounts, @expense_by_currency, account_translated)

      # The bottom line, per currency and translated. This was subtracted in
      # the template; it is the headline figure of the statement.
      net_totals = Hash.new(0)
      currencies_with_data.each { |curr| net_totals[curr] = income_totals[curr] - expense_totals[curr] }

      [ account_translated, {
        income_by_currency:  income_totals,
        expense_by_currency: expense_totals,
        net_by_currency:     net_totals,
        translated_income:   translated_income,
        translated_expense:  translated_expense,
        translated_net:      translated_income - translated_expense
      } ]
    end

    private

    # Income and expenditure are summed identically — only the buckets differ.
    # Written out twice in the controller before, which is how the two copies
    # could have drifted.
    def sum_side(accounts, by_currency, account_translated)
      totals          = Hash.new(0)
      translated_side = 0

      accounts.each do |account|
        balances = by_currency[account.id] || {}
        currencies_with_data.each { |curr| totals[curr] += balances[curr] || 0 }

        translated = translate_monthly(@balances_by_month[account.id] || {}, account)
        account_translated[account.id] = translated
        translated_side += translated
      end

      [ totals, translated_side ]
    end
  end
end
