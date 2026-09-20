# frozen_string_literal: true

class YearEndService
  attr_reader :entity, :start_date, :end_date

  def initialize(entity:, start_date:, end_date:)
    @entity     = entity
    @start_date = start_date
    @end_date   = end_date
  end

  # Returns an array of posted JournalEntries, one per currency, or [] if there
  # is nothing to close. One transaction: a multi-currency close is all-or-
  # nothing, and callers wrap this in an advisory lock on the scope so a
  # concurrent close re-reads net_balances and finds nothing left.
  #
  # Raises Current.app_closing_entry_write here rather than trusting every
  # caller to remember: this is the one place a fresh closing entry is
  # legitimately built, so it is the one place that gets to assert it.
  # JournalEntry#app_owned_close_is_read_only refuses anyone else's attempt to
  # post into the retained-earnings account it creates.
  def call
    # Restore rather than force false: a caller, or a test re-validating the
    # result right after, may already have the flag raised around this call, and
    # clearing it unconditionally would drop it out from under them the moment
    # #call returns.
    previous_write = Current.app_closing_entry_write
    Current.app_closing_entry_write = true
    ApplicationRecord.transaction do
      balances = net_balances
      next [] if balances.empty?

      currencies = balances.keys
      re_accounts = find_or_create_retained_earnings(currencies)

      currencies.map { |currency| build_journal_entry(currency, balances[currency], re_accounts[currency]) }
    end
  ensure
    Current.app_closing_entry_write = previous_write
  end

  def nothing_to_close?
    net_balances.empty?
  end

  private

  def net_balances
    @net_balances ||= calculate_net_balances
  end

  # Personal (drawings) accounts close alongside income and expense. A drawing
  # is a distribution, not a loss, so it belongs in retained earnings by the
  # year end — otherwise the balance sits on a nominal account for ever and
  # reads as a phantom loss in the balance-sheet residual.
  #
  # A partnership wanting per-partner capital or clearing accounts builds those
  # as equity (3xx) and clears drawings in-year; anything left on a 6xx account
  # at the close is a drawing that slipped through, and closing it here makes it
  # visible.
  def calculate_net_balances
    accounts = Account.active
      .where(account_type: [:income, :expense, :personal])
      .for_entity_codes([entity.code])
      .to_a
    return {} if accounts.empty?

    by_id = accounts.index_by(&:id)

    # bucket: :total — one signed figure per (account, currency) for the whole
    # period, no translation, since each currency closes separately. The sign is
    # Account#debit_normal?, the same one every report uses. include_closing:
    # true makes no practical difference: an unclosed period never contains a
    # closing entry, because reopening deletes them first.
    balances = Reports::LedgerBalances.new(
      accounts: accounts, from: start_date, to: end_date,
      bucket: :total, include_closing: true
    ).call

    result = {}
    balances.each do |account_id, buckets|
      buckets.each_value do |by_currency|
        by_currency.each do |currency, net|
          result[currency] ||= {}
          result[currency][account_id] = { account: by_id[account_id], net: net }
        end
      end
    end
    result
  end

  def existing_re_accounts
    @existing_re_accounts ||= Account.retained_earnings
      .for_entity_codes([entity.code])
  end

  def find_or_create_retained_earnings(currencies)
    re_by_currency = existing_re_accounts.index_by(&:currency)
    parent = find_or_create_re_parent
    used_nums = existing_re_accounts.pluck(:code).map { |c| c[-2..].to_i }

    currencies.each_with_object({}) do |currency, hash|
      hash[currency] = re_by_currency[currency] || create_re_account(currency, parent, used_nums)
    end
  end

  def find_or_create_re_parent
    code = "3#{entity.code}900"
    Account.find_by(code: code) || Account.create!(
      code: code,
      name: I18n.t("reports.year_end.retained_earnings_parent"),
      account_type: :equity,
      active: true,
      locked: true
    )
  end

  def create_re_account(currency, parent, used_nums)
    next_num = (1..99).find { |n| !used_nums.include?(n) }
    used_nums << next_num
    code = "3#{entity.code}9#{next_num.to_s.rjust(2, '0')}"

    Account.create!(
      code: code,
      name: "#{I18n.t("reports.year_end.retained_earnings")} #{currency}",
      account_type: :equity,
      currency: currency,
      parent: parent,
      active: true,
      locked: true
    )
  end

  def build_journal_entry(currency, account_balances, re_account)
    posting_description = I18n.t("reports.year_end.closing_entry_description", date: I18n.l(end_date, format: :short_date))

    je = JournalEntry.new(
      entry_date: end_date,
      memo: I18n.t("reports.year_end.closing_entry_memo", year: end_date.year, currency: currency),
      posted: false,
      closing_entry: true,
      period_start: start_date,
      period_end: end_date
    )

    re_net = 0
    account_balances.each_value do |data|
      account = data[:account]
      net     = data[:net]

      if account.income?
        je.postings.build(account: account, entry_type: :debit, amount: net, description: posting_description)
        re_net += net
      else
        je.postings.build(account: account, entry_type: :credit, amount: net, description: posting_description)
        re_net -= net
      end
    end

    # The retained-earnings leg is always built, even for a break-even year. It
    # is the entry's single balance-sheet posting — the one that carries a
    # currency, and that every nominal leg derives its currency from — and there
    # is one RE account per currency whatever the amount.
    entry_type = re_net >= 0 ? :credit : :debit
    je.postings.build(account: re_account, entry_type: entry_type, amount: re_net.abs)

    # Nominal legs are left currency-less on purpose: set_currency_from_account
    # stamps the RE leg, clear_currency_for_nominal_accounts keeps the rest
    # null, and the balancing validations run as they do for any entry.
    je.posted = true
    je.posted_will_change!
    je.save!
    je
  end
end
