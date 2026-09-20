# frozen_string_literal: true
require "test_helper"

class Reports::LedgerBalancesTest < ActiveSupport::TestCase
  # The aggregator's type list must stay in step with Account#debit_normal?.
  test "DEBIT_NORMAL_TYPES matches Account#debit_normal? for every type" do
    Account.account_types.each_key do |name|
      assert_equal Account.new(account_type: name).debit_normal?,
        Reports::LedgerBalances::DEBIT_NORMAL_TYPES.include?(name),
        "#{name}: type list and debit_normal? disagree"
    end
  end

  # Reproduce the current fetch_balances_by_currency_and_month exactly and
  # compare — the migration must not move a single figure.
  def legacy_fetch_balances(account_ids, from:, to:, exclude_closing:)
    accounts = Account.where(id: account_ids).index_by(&:id)
    csql = Posting.effective_currency_sql
    scope = Posting.joins(:journal_entry, :account)
      .where(account_id: account_ids)
      .where(journal_entries: { posted: true })
      .where("journal_entries.entry_date <= ?", to)
      .joins(Posting.currency_join_sql)
    scope = scope.where("journal_entries.entry_date >= ?", from) if from
    scope = scope.where("journal_entries.closing_entry IS NOT TRUE") if exclude_closing

    month_sql = "date_trunc('month', journal_entries.entry_date)"
    out = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = {} } }
    scope.group(:account_id, Arel.sql(csql), Arel.sql(month_sql))
      .pluck(:account_id, Arel.sql(csql), Arel.sql(month_sql),
        Arel.sql("SUM(CASE WHEN postings.entry_type = 0 THEN postings.amount ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN postings.entry_type = 1 THEN postings.amount ELSE 0 END)"))
      .each do |account_id, currency, month, debits, credits|
        next if currency.blank?
        account = accounts[account_id]
        next unless account
        balance = account.debit_normal? ? (debits - credits) : (credits - debits)
        next if balance == 0
        out[account_id][month.to_date][currency] = balance
      end
    out.transform_values { |v| v.transform_values(&:to_h).to_h }.to_h
  end

  test "net monthly output equals the legacy fetch_balances, closing excluded" do
    ids = Account.where(account_type: %i[income expense]).pluck(:id)
    from = Date.new(2015, 1, 1)
    to   = Date.current

    legacy = legacy_fetch_balances(ids, from: from, to: to, exclude_closing: true)
    fresh  = Reports::LedgerBalances.new(account_ids: ids, from: from, to: to,
                                         bucket: :month, include_closing: false).call
    fresh  = fresh.transform_values { |v| v.transform_values(&:to_h).to_h }.to_h

    assert_equal legacy, fresh
  end

  test "net monthly output equals the legacy fetch_balances, closing included" do
    ids = Account.where(account_type: %i[asset liability equity]).pluck(:id)
    to  = Date.current

    legacy = legacy_fetch_balances(ids, from: nil, to: to, exclude_closing: false)
    fresh  = Reports::LedgerBalances.new(account_ids: ids, to: to, bucket: :month,
                                         include_closing: true).call
    fresh  = fresh.transform_values { |v| v.transform_values(&:to_h).to_h }.to_h

    assert_equal legacy, fresh
  end

  test ":total bucket sums the whole range into one bucket dated `to`" do
    ids = Account.where(account_type: %i[income expense]).pluck(:id)
    to  = Date.current

    monthly = Reports::LedgerBalances.new(account_ids: ids, to: to, bucket: :month).call
    total   = Reports::LedgerBalances.new(account_ids: ids, to: to, bucket: :total).call

    monthly.each do |account_id, by_month|
      per_currency = Hash.new(0)
      by_month.each_value { |c| c.each { |cur, amt| per_currency[cur] += amt } }
      assert_equal per_currency.to_h, total.fetch(account_id).fetch(to),
        "account #{account_id}: :total should equal the sum of :month buckets"
    end
  end

  test "net: false keeps debit and credit apart" do
    ids = Account.where(account_type: %i[income expense]).pluck(:id)
    res = Reports::LedgerBalances.new(account_ids: ids, to: Date.current,
                                      bucket: :month, net: false).call
    res.each_value do |by_bucket|
      by_bucket.each_value do |by_curr|
        by_curr.each_value do |v|
          assert_kind_of Hash, v
          assert v.key?(:debit) && v.key?(:credit)
        end
      end
    end
  end

  test "line_items returns signed per-posting rows" do
    ids = Account.where(account_type: %i[income expense]).pluck(:id)
    rows = Reports::LedgerBalances.new(account_ids: ids, to: Date.current).line_items
    assert rows.any?
    rows.each do |r|
      assert_kind_of Integer, r.amount
      assert r.currency.present?
      assert_kind_of Date, r.date.to_date
    end
  end
end
