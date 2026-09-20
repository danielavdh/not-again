# frozen_string_literal: true
require "test_helper"

# THREE ACTS, THREE LEVELS OF AUTHORITY:
#
# add / edit    full access — a currency cannot make a figure wrong
# delete        full access, but ONLY while nothing rests on it
# deactivate    SUDO, and it means the currency has CEASED TO EXIST
#
# Delete silently becoming deactivate once a currency was in use let a full-
# access admin retire a currency — globally, for every admin and every entity,
# stopping its rates being fetched — from a button labelled Delete. `active` was
# also a permitted attribute on the form, while code and symbol were guarded.
class CurrenciesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @unused = Currency.create!(code: "NOK", symbol: "kr")
  end

  def used_currency
    Currency.find_by(code: "GBP").tap { |c| assert c.in_use?, "fixture GBP should be in use" }
  end

  # ---- retiring is sudo's ----

  test "a full-access admin cannot deactivate anything" do
    sign_in_as(admins(:one))
    patch deactivate_currency_path(@unused)

    assert_redirected_to currencies_path
    assert @unused.reload.active?, "a full-access admin must not retire a currency for everyone"
  end

  test "nor reactivate" do
    @unused.update!(active: false)
    sign_in_as(admins(:one))
    patch reactivate_currency_path(@unused)

    assert_not @unused.reload.active?
  end

  test "sudo may, when nothing has been posted to it" do
    sign_in_as(admins(:sudo))
    patch deactivate_currency_path(@unused)

    assert_not @unused.reload.active?, "nothing has ever been posted in NOK here, so it can be retired"
  end

  # Retirement asks whether OUR OWN books have posted to a currency recently,
  # not whether a SOURCE still publishes it — which is true of nearly every real
  # currency, forever, and so not a meaningful signal. The real risk is a report
  # not yet finished that still needs it. No override, sudo included.
  test "and is refused when there has been a recent posting" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101997", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401997", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!
    sign_in_as(admins(:sudo))

    patch deactivate_currency_path(currency)

    assert currency.reload.active?, "posted to this recently — must not be retired, even by sudo"
    assert flash[:alert].present?, "and says why"
  end

  # ⚠️ RECENTLY, not ever. A currency used years ago and never since must not
  # be permanently unretirable — that IS the case this feature exists for.
  test "old postings do not keep a currency unretirable forever" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101997", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401997", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: 3.months.ago.to_date)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!
    je.update_column(:created_at, 3.months.ago)
    sign_in_as(admins(:sudo))

    patch deactivate_currency_path(currency)

    assert_not currency.reload.active?, "activity three months ago must not block retirement forever"
  end

  # A8: entry_date is user-editable and must not be what protects a currency.
  test "a backdated entry does not let a currency slip past the retirement guard" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101997", name: "ZQX account", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401997", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: 5.years.ago.to_date)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!
    sign_in_as(admins(:sudo))

    patch deactivate_currency_path(currency)

    assert currency.reload.active?, "created just now, whatever the entry_date claims"
  end

  # ---- delete no longer becomes deactivate ----

  test "deleting a currency in use is refused outright" do
    sign_in_as(admins(:one))
    gbp = used_currency

    assert_no_difference -> { Currency.count } do
      delete currency_path(gbp)
    end
    assert gbp.reload.active?, "it must not be quietly deactivated instead"
  end

  test "deleting an unused one is ordinary housekeeping" do
    sign_in_as(admins(:one))

    assert_difference -> { Currency.count }, -1 do
      delete currency_path(@unused)
    end
  end

  test "deleting a currency held only as an admin's preference is refused too" do
    admins(:one).update!(preferred_currency: @unused.code)
    sign_in_as(admins(:one))

    assert_no_difference -> { Currency.count } do
      delete currency_path(@unused)
    end
  end

  # ---- active is not an attribute anyone can submit ----

  # A disabled field is a suggestion; a crafted request is not. `active` was
  # permitted alongside code and symbol, so this went straight through.
  test "active cannot be set through the form, even by sudo" do
    sign_in_as(admins(:sudo))
    patch currency_path(@unused), params: { currency: { active: "0", symbol: "kr." } }

    assert @unused.reload.active?, "retiring is a named action, not a form field"
    assert_equal "kr.", @unused.symbol, "the fields that ARE the form's still work"
  end

  test "a settled currency keeps its code and symbol against a crafted request" do
    sign_in_as(admins(:one))
    gbp = used_currency
    before = [ gbp.code, gbp.symbol ]

    patch currency_path(gbp), params: { currency: { code: "XXX", symbol: "!" } }

    gbp.reload
    assert_equal before, [ gbp.code, gbp.symbol ]
  end

  # ---- settled? is now POSTED?, not merely "has an account" (2026-09-17) ----

  test "a full-access admin CAN now fix the code on a currency with an account but no postings" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101998", name: "Unposted", account_type: :asset,
                               currency: "ZQX", active: true)
    sign_in_as(admins(:one))

    patch currency_path(currency), params: { currency: { code: "ZQY", symbol: "Z" } }

    currency.reload
    assert_equal [ "ZQY", "Z" ], [ currency.code, currency.symbol ]
    assert_equal "ZQY", account.reload.currency, "the cascade must reach the account too"
  end

  test "a full-access admin is still refused once a posting carries the currency" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101998", name: "Posted", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401998", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!
    sign_in_as(admins(:one))

    patch currency_path(currency), params: { currency: { code: "ZQY", symbol: "Z" } }

    assert_equal "ZQX", currency.reload.code, "a full-access admin must not fix a POSTED currency"
  end

  test "sudo CAN fix a posted currency's code, and it cascades to the account and its postings" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101998", name: "Posted", account_type: :asset,
                               currency: "ZQX", active: true)
    income = Account.create!(code: "401998", name: "ZQX income", account_type: :income, active: true)
    je = JournalEntry.new(entry_date: Date.current)
    je.postings.build(account: account, amount: 500, entry_type: :debit, currency: "ZQX")
    je.postings.build(account: income, amount: 500, entry_type: :credit)
    je.save!
    balance_posting = je.postings.detect { |p| p.account_id == account.id }
    sign_in_as(admins(:sudo))

    patch currency_path(currency), params: { currency: { code: "ZQY", symbol: "Z" } }

    assert_equal "ZQY", currency.reload.code
    assert_equal "ZQY", account.reload.currency
    assert_equal "ZQY", balance_posting.reload.currency
  end

  # ---- A6: concurrent renames no longer silently orphan the loser's edit ----

  test "a second admin's stale rename is refused, not silently applied on top of the first" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    account = Account.create!(code: "101998", name: "Unposted", account_type: :asset,
                               currency: "ZQX", active: true)
    # Two admins load the SAME row independently, same as two browser tabs.
    stale_copy = Currency.find(currency.id)
    sign_in_as(admins(:one))

    patch currency_path(currency), params: { currency: { code: "ZQY", symbol: "Z", lock_version: currency.lock_version } }
    assert_equal "ZQY", currency.reload.code

    patch currency_path(stale_copy), params: { currency: { code: "ZQZ", symbol: "Z", lock_version: stale_copy.lock_version } }

    assert_response :conflict
    assert_equal "ZQY", currency.reload.code, "the first admin's committed rename must survive"
    assert_equal "ZQY", account.reload.currency, "the cascade must not be undone or duplicated"
    assert_not Currency.exists?(code: "ZQZ"), "the losing rename must not create an orphan row"
  end

  # The test above builds its params by hand, so it proves the controller
  # refuses a stale version — not that the app ever SENDS one. It did not:
  # Rails does not emit lock_version on its own, so every real submit carried
  # the row's current value and the conflict could never arise. Green test,
  # unreachable guard.
  test "the edit form actually sends the version the guard checks" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    sign_in_as(admins(:sudo))

    get edit_currency_path(currency, locale: :en)

    assert_select "input[name=?][value=?]", "currency[lock_version]",
                  currency.lock_version.to_s
  end

  # What a second browser tab actually does: load the form, let someone else
  # save, then submit the page as rendered.
  test "a rename from a page loaded before someone else's rename is refused" do
    currency = Currency.create!(code: "ZQX", symbol: "z")
    sign_in_as(admins(:sudo))

    get edit_currency_path(currency, locale: :en)
    rendered_version = css_select("input[name='currency[lock_version]']").first["value"]

    Currency.find(currency.id).update!(code: "ZQY")

    patch currency_path(currency, locale: :en),
          params: { currency: { code: "ZQZ", symbol: "z", lock_version: rendered_version } }

    assert_response :conflict
    assert_equal "ZQY", currency.reload.code
  end
end
