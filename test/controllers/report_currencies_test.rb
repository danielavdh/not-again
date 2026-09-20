# frozen_string_literal: true
require "test_helper"

# THE FULL CURRENCY LIST BELONGS IN EXACTLY TWO PLACES: the account form and the
# exchange rate form. Those are where a currency ARRIVES.
#
# Everywhere else you are working with money that already exists, and the full
# list is noise — with twenty-five currencies the report dropdown is not twenty-
# five options but FIFTY, because it is currency × source.
class ReportCurrenciesTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:one)
  end

  def report_currencies_for(admin)
    used  = Currency.used_codes(scope: admin.accessible_accounts)
    bases = RateSourceConfig.bases.values.to_set
    CurrencyConfig.available.select { |c| used.include?(c) || bases.include?(c) }
  end

  # The whole point: the list a report offers does not grow with the list the
  # installation supports.
  test "adding currencies does not lengthen the report dropdown" do
    before = report_currencies_for(@admin)

    %w[NOK SEK PLN HUF CZK].each { |c| Currency.create!(code: c, symbol: c) }
    Currency.expire_cache

    assert_equal before, report_currencies_for(@admin),
                 "five unused currencies must not appear where money is only being read"

    %w[NOK SEK PLN HUF CZK].each do |code|
      assert_includes CurrencyConfig.available, code,
                      "but the account form still offers #{code} — it is where a currency arrives"
    end
  end

  # ⚠️ Scoped to the admin. Unscoped, an admin whose one business keeps euros
  # was
  # offered francs and sterling belonging to entities they cannot even open.
  test "one admin's currencies are not another's" do
    mine = Currency.used_codes(scope: @admin.accessible_accounts)
    all  = Currency.used_codes

    assert_operator mine.size, :<=, all.size
    mine.each { |c| assert_includes all, c }
  end

  # A GBP/CHF business can still read its report in euros for a German reader,
  # even with no euro account, because every source's BASE currency is offered.
  test "the base currency of every source is always offered" do
    offered = report_currencies_for(@admin)

    RateSourceConfig.bases.each_value do |base|
      next unless CurrencyConfig.available.include?(base)
      assert_includes offered, base, "#{base} is a source's base — it must be convertible into"
    end
  end

  test "and a currency an account actually holds, even if no source is based on it" do
    Currency.create!(code: "NOK", symbol: "kr")
    Account.create!(code: "101998", name: "Oslo bank", account_type: :asset,
                         currency: "NOK", active: true)
    Currency.expire_cache

    assert_includes report_currencies_for(admins(:sudo)), "NOK",
                    "money that exists is always worth converting"
  end

  # Deactivated currencies are gone from every picker, including this one.
  test "a retired currency is offered nowhere" do
    Currency.create!(code: "NOK", symbol: "kr")
    Account.create!(code: "101997", name: "Oslo bank", account_type: :asset,
                         currency: "NOK", active: true)
    Currency.expire_cache
    assert_includes report_currencies_for(admins(:sudo)), "NOK"

    Currency.find_by(code: "NOK").update!(active: false)
    Currency.expire_cache

    assert_not_includes report_currencies_for(admins(:sudo)), "NOK"
    assert_equal "kr", CurrencyConfig.symbol_for("NOK"), "but the money it holds still reads right"
  end
end
