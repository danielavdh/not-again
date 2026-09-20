# frozen_string_literal: true
require "test_helper"
require "minitest/mock"

# Adding a currency is DATA, and an admin's to do.
#
# Two constraints shape this class: symbol_for runs on EVERY formatted amount,
# so the lookup must be memoised; and it is read very early, so it must survive
# there being no database at all.
class CurrencyTest < ActiveSupport::TestCase
  setup { Currency.expire_cache }
  teardown { Currency.expire_cache }

  # The order is a RULE, not a field an admin sets, because it is GLOBAL — an
  # editable `position` let one admin reorder every other admin's report
  # columns.
  #
  # 1. everything an account actually uses, alphabetically
  # 2. everything else, alphabetically
  #
  # Two groups and no third. Pinning EUR, GBP and USD means taking a view on
  # which currencies matter, and taking it again the day the renminbi turns up;
  # the usage rule already does that job.
  test "used currencies come first, each group alphabetical" do
    used, rest = CurrencyConfig.available.partition { |c| Currency.used_codes.include?(c) }

    assert_equal used.sort, used, "used currencies are alphabetical among themselves"
    assert_equal rest.sort, rest, "and so are the rest"
    assert_equal used + rest, CurrencyConfig.available, "used first, then the rest"
  end

  test "a currency in use outranks one that is not" do
    Currency.create!(code: "AAA", symbol: "a")   # unused, sorts first alphabetically
    Currency.create!(code: "ZZZ", symbol: "z")
    # Six digits: type, then the two-digit entity, then three. A NEW account,
    # because an existing one refuses to change currency once it has postings.
    Account.create!(code: "101999", name: "Zed bank", account_type: :asset,
                         currency: "ZZZ", active: true)
    Currency.expire_cache

    tail = CurrencyConfig.available - %w[EUR GBP USD]
    assert_operator tail.index("ZZZ"), :<, tail.index("AAA"),
                    "a currency with an account beats an unused one, whatever the alphabet"
  end

  test "unused currencies sort alphabetically among themselves" do
    Currency.create!(code: "AAA", symbol: "a")
    Currency.create!(code: "BBB", symbol: "b")
    Currency.expire_cache

    unused = CurrencyConfig.available & %w[AAA BBB]
    assert_equal %w[AAA BBB], unused
  end

  # The whole point of the feature.
  test "an admin adding one is visible at once, with no restart" do
    Currency.create!(code: "UAH", symbol: "₴", position: 99)

    assert_includes CurrencyConfig.available, "UAH"
    assert_equal "₴", CurrencyConfig.symbol_for("UAH")
  end

  # symbol_pattern must not be memoised forever: a currency added while the app
  # is running would then fail to parse on paste until the next restart —
  # silently, as a blank field.
  test "a new currency parses on paste immediately" do
    Currency.create!(code: "UAH", symbol: "₴", position: 99)

    assert_equal 123_456, CurrencyConfig.parse_to_cents("1 234,56 ₴")
  end

  test "deactivating one removes it from the pickers" do
    Currency.find_by(code: "USD").update!(active: false)

    assert_not_includes CurrencyConfig.available, "USD"
  end

  # Deactivating is about what may be CHOSEN, never about what a stored figure
  # looks like. A cache filtered by `active` stripped a switched-off currency's
  # symbol from every amount in it — "CHF 1,234.56" became "1,234.56", globally,
  # for every admin — while the flash said "Existing figures keep their symbol".
  test "but it keeps its symbol, because existing figures still carry it" do
    Currency.find_by(code: "USD").update!(active: false)

    assert_equal "$", CurrencyConfig.symbol_for("USD")
    assert_equal "$1,234.56", CurrencyConfig.format_cents(123_456, "USD")
  end

  # And it must still PARSE, or editing an old amount in that currency silently
  # blanks the field.
  test "and it still parses on paste" do
    Currency.find_by(code: "USD").update!(active: false)

    assert_equal 123_456, CurrencyConfig.parse_to_cents("$1,234.56")
  end

  # ---- surviving no database ----

  test "no table falls back to the seed constant" do
    Currency.stub(:table_exists?, false) do
      Currency.expire_cache
      assert_equal CurrencyConfig::SYMBOLS.keys, CurrencyConfig.available
    end
  end

  test "no connection falls back too" do
    raiser = ->(*) { raise ActiveRecord::ConnectionNotEstablished }

    Currency.stub(:table_exists?, raiser) do
      Currency.expire_cache
      assert_equal CurrencyConfig::SYMBOLS.keys, CurrencyConfig.available
    end
  end

  # THE ONE THAT BIT. An empty table is not "supports no currencies": it is what
  # a database built from schema.rb has, because the seeding lives in the
  # migration. A fresh install, a restored dump and the test database all arrive
  # here. Returning {} emptied every currency dropdown and stripped the symbol
  # from every amount, silently.
  test "an empty table falls back rather than reporting no currencies" do
    Currency.delete_all
    Currency.expire_cache

    assert_equal CurrencyConfig::SYMBOLS.keys, CurrencyConfig.available
    assert_equal "€", CurrencyConfig.symbol_for("EUR")
  end

  # ---- the cache ----

  test "the list is not queried once per formatted amount" do
    CurrencyConfig.symbol_for("EUR") # prime

    queries = 0
    counter = ->(_n, _s, _f, _i, p) { queries += 1 if p[:sql]&.include?("currencies") }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      100.times { CurrencyConfig.symbol_for("EUR") }
    end

    assert_equal 0, queries, "a trial balance formats hundreds of amounts"
  end

  test "a write in this process expires the cache" do
    CurrencyConfig.available # prime
    Currency.create!(code: "NOK", symbol: "kr", position: 50)

    assert_includes CurrencyConfig.available, "NOK"
  end

  # ---- validation ----

  test "a code is three letters, uppercased, and unique" do
    assert Currency.new(code: "nok", symbol: "kr").valid?
    assert_equal "NOK", Currency.new(code: " nok ", symbol: "kr").tap(&:valid?).code

    assert_not Currency.new(code: "NO", symbol: "kr").valid?
    assert_not Currency.new(code: "N0K", symbol: "kr").valid?, "digits are not a currency code"
    assert_not Currency.new(code: "EUR", symbol: "€").valid?, "already supported"
    assert_not Currency.new(code: "NOK", symbol: "").valid?, "a symbol is required"
  end

  # ---- recently_active? (audit-2 A8, renamed + fixed 2026-09-19) ----

  test "recently_active? is false with no postings at all" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    assert_not currency.recently_active?
  end

  test "recently_active? is true for a posting created within the last two months" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101997", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401997", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!

    assert currency.recently_active?
  end

  test "recently_active? is false once the posting was actually created over two months ago" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101997", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401997", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!
    je.update_column(:created_at, 3.months.ago)

    assert_not currency.recently_active?
  end

  # A8: entry_date is user-editable and must not be what protects a currency.
  test "recently_active? is true even when the journal entry's own date is backdated" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101997", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401997", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: 5.years.ago.to_date)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!

    assert currency.recently_active?, "created just now, whatever the entry_date claims"
  end

  # A8: an admin mid-entry is exactly who this guard protects, and a draft is
  # exactly that case.
  test "recently_active? also protects a currency held only by an unposted draft entry" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101997", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401997", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!
    je.unpost!
    assert_not je.posted?, "the entry must genuinely be a draft for this test to mean anything"

    assert currency.recently_active?
  end

  # ---- settled?/posted? vs in_use? (2026-09-17) ----

  test "posted? and settled? are false for a currency with an account but no postings" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    Account.create!(code: "101998", name: "Unposted ZQX account", account_type: :asset,
                     currency: "ZQX", active: true)

    assert_not currency.posted?
    assert_not currency.settled?
  end

  test "in_use? stays true for an account with no postings — nothing to migrate to on a delete" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    Account.create!(code: "101998", name: "Unposted ZQX account", account_type: :asset,
                     currency: "ZQX", active: true)

    assert currency.in_use?, "delete must still be blocked — deleting has no new code to move to"
  end

  test "posted? and settled? become true once a posting actually carries the code" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101998", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401998", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!

    assert currency.posted?
    assert currency.settled?
  end

  # ---- migrate_dependents_to_new_code (2026-09-17) ----

  test "renaming an unposted currency's code migrates its account, not just the Currency row" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101998", name: "Typo'd account", account_type: :asset,
                               currency: "ZQX", active: true)

    currency.update!(code: "ZQY")

    assert_equal "ZQY", account.reload.currency
  end

  test "renaming a posted currency's code migrates the account AND its postings" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101998", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401998", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!
    balance_posting = je.postings.detect { |p| p.account_id == account.id }

    currency.update!(code: "ZQY")

    assert_equal "ZQY", account.reload.currency
    assert_equal "ZQY", balance_posting.reload.currency
  end

  test "renaming a currency's code migrates exchange rates carrying it, both directions" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    from_row = ExchangeRate.create!(from_currency: "ZQX", to_currency: "EUR", source: "manual",
                                     rate: 1.1, effective_date: Date.current,
                                     valid_from: Date.current, valid_to: Date.current)
    to_row = ExchangeRate.create!(from_currency: "GBP", to_currency: "ZQX", source: "manual",
                                   rate: 1.2, effective_date: Date.current - 1,
                                   valid_from: Date.current - 1, valid_to: Date.current - 1)

    currency.update!(code: "ZQY")

    assert_equal "ZQY", from_row.reload.from_currency
    assert_equal "ZQY", to_row.reload.to_currency
  end

  # The realistic case: fixing "EUT" to "EUR" almost certainly finds real EUR
  # history already under the target code — a stray row from an earlier,
  # separate incident, since exchange_rates carries no FK to Currency at all and
  # a code with no live Currency row can still have real rows under it.
  #
  # Renaming INTO an existing Currency's own code is blocked outright by
  # Currency's uniqueness validation before this ever runs. This collision is
  # specifically the orphaned-data case.
  test "an exchange rate that would collide with one already under the target code is dropped, not left stuck" do
    currency = Currency.create!(code: "EUT", symbol: "€")
    date = Date.current
    # Orphaned: no Currency row named EUZ exists, but a rate row under that
    # code does — exactly the leftover-from-an-earlier-typo shape.
    ExchangeRate.create!(from_currency: "EUZ", to_currency: "GBP", source: "ecb", rate: 0.85,
                          effective_date: date, valid_from: date, valid_to: date)
    duplicate = ExchangeRate.create!(from_currency: "EUT", to_currency: "GBP", source: "ecb", rate: 0.85,
                                      effective_date: date, valid_from: date, valid_to: date)

    currency.update!(code: "EUZ")

    assert_not ExchangeRate.exists?(duplicate.id), "the redundant EUT row should have been dropped"
    assert_equal 1, ExchangeRate.where(from_currency: "EUZ", to_currency: "GBP", valid_from: date).count
  end

  # ---- admins.preferred_currency (A7, audit-2) ----

  test "renaming a currency's code migrates an admin's preferred_currency too" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    admins(:one).update!(preferred_currency: "ZQX")

    currency.update!(code: "ZQY")

    assert_equal "ZQY", admins(:one).reload.preferred_currency
  end

  test "an admin's own preferred_currency does not migrate someone else's" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    admins(:one).update!(preferred_currency: "ZQX")

    currency.update!(code: "ZQY")

    assert_nil admins(:two).reload.preferred_currency
  end

  test "in_use? is true when an admin holds the code as their preference, even with no accounts" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    admins(:one).update!(preferred_currency: "ZQX")

    assert currency.in_use?, "deleting must not leave an admin's preference pointing at nothing"
  end

  test "deactivating a currency clears it from any admin's preference rather than leaving it dangling" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    admins(:one).update!(preferred_currency: "ZQX")
    admins(:two).update!(preferred_currency: "ZQX")

    currency.update!(active: false)

    assert_nil admins(:one).reload.preferred_currency
    assert_nil admins(:two).reload.preferred_currency
  end

  test "deactivating a currency leaves an unrelated admin's preference untouched" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    admins(:one).update!(preferred_currency: "GBP")

    currency.update!(active: false)

    assert_equal "GBP", admins(:one).reload.preferred_currency
  end

  test "reactivating does not touch preferred_currency" do
    currency = Currency.create!(code: "ZQX", symbol: "z", active: false)
    admins(:one).update!(preferred_currency: "GBP")

    currency.update!(active: true)

    assert_equal "GBP", admins(:one).reload.preferred_currency
  end

  test "changing only the symbol does not trigger the migration at all" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101998", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)

    currency.update!(symbol: "Z$")

    assert_equal "ZQX", account.reload.currency, "no code change, nothing should have moved"
  end

  # --- minor_unit ---
  #
  # Nothing reads this yet; it is recorded so a currency added before the rest
  # of the work lands is already carrying the right answer. These assert the
  # arithmetic of real currencies, not that the lookup table equals itself.

  test "a currency with no subunit is recorded as having none" do
    assert_equal 0, Currency.create!(code: "JPY", symbol: "¥").minor_unit,
      "a yen has no subunit at all — ¥100 is the smallest unit"
    assert_equal 0, Currency.create!(code: "ISK", symbol: "kr").minor_unit,
      "Iceland abolished the aurar in 2003"
  end

  test "a currency divided into a thousand is recorded as three places" do
    assert_equal 3, Currency.create!(code: "KWD", symbol: "د.ك").minor_unit,
      "a Kuwaiti dinar is 1000 fils, not 100"
    assert_equal 3, Currency.create!(code: "BHD", symbol: ".د.ب").minor_unit
  end

  test "an ordinary currency is two places" do
    assert_equal 2, Currency.create!(code: "SEK", symbol: "kr").minor_unit
    assert_equal 2, Currency.create!(code: "NZD", symbol: "$").minor_unit
  end

  # A code ISO has invented since is a pull request, not a runtime guess —
  # guessing wrong is money out by a factor of a hundred.
  test "a code the table has never heard of falls back to two, not to nothing" do
    currency = Currency.create!(code: "ZZZ", symbol: "z")

    assert_equal 2, currency.minor_unit
    assert currency.valid?
  end

  # Correcting a typo already cascades every account, posting and rate; the
  # decimal places have to travel with them or the corrected code keeps the
  # wrong ones forever.
  test "correcting a mistyped code brings its decimal places with it" do
    currency = Currency.create!(code: "JPZ", symbol: "¥")
    assert_equal 2, currency.minor_unit, "precondition: JPZ is not a real code, so it defaulted"

    currency.update!(code: "JPY")

    assert_equal 0, currency.reload.minor_unit,
      "renamed to a real zero-decimal currency, but kept the default"
  end

  test "the fixtures' own currencies are all two places" do
    assert_equal [ 2 ], Currency.where(code: %w[GBP EUR USD CHF]).distinct.pluck(:minor_unit)
  end
end
