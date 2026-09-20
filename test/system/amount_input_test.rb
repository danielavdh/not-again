require "application_system_test_case"

# The server parsing an amount string with one rule and the JavaScript beside it
# with another — and the JavaScript never writing its result back into the field
# — means the number on screen and the number saved can differ: a European
# typing "1,5" stored ten euros fifty, not one fifty.
#
# The fix is one shared parser (CurrencyConfig#parse_to_cents in Ruby,
# parseAmountToCents in scripts/utils.js; currency_config_test holds the parity
# table) and an on-blur reformat, so an amount field shows the value back the
# way the app actually read it. This test is the browser half: a real field and
# a real blur.
class AmountInputTest < ApplicationSystemTestCase
  setup do
    sign_in_system(admins(:two))
  end

  # "1,5" is one-and-a-half in every language whose decimal mark is a comma —
  # the ordinary way to write half of something. It must not become 1500.
  test "a one-decimal-place amount self-corrects to the read value on blur, in English" do
    visit app_url("/en/journal_entries/new")

    field = first("input.posting-amount")
    field.set("1,5")
    field.native.send_keys(:tab)

    assert_equal "1.50", first("input.posting-amount").value
  end

  test "the same amount self-corrects in the format of the current language" do
    visit app_url("/de/journal_entries/new")

    field = first("input.posting-amount")
    field.set("1,5")
    field.native.send_keys(:tab)

    assert_equal "1,50", first("input.posting-amount").value
  end

  # The one genuine ambiguity — "1.234" / "1,234", a lone separator before three
  # digits — is read as thousands grouping. The point of the reformat is that
  # the user SEES it happen and can fix it before saving, rather than
  # discovering it in the books.
  test "a lone separator before three digits shows back as grouped thousands" do
    visit app_url("/en/journal_entries/new")

    field = first("input.posting-amount")
    field.set("1.234")
    field.native.send_keys(:tab)

    assert_equal "1,234.00", first("input.posting-amount").value
  end

  test "an amount already in the display format is left exactly as typed" do
    visit app_url("/en/journal_entries/new")

    field = first("input.posting-amount")
    field.set("1,234.56")
    field.native.send_keys(:tab)

    assert_equal "1,234.56", first("input.posting-amount").value
  end

  # A value the app cannot read is left as the user typed it: the server rejects
  # it with a real error rather than the field silently blanking or inventing a
  # number.
  test "an unparseable amount is left untouched for the server to reject" do
    visit app_url("/en/journal_entries/new")

    field = first("input.posting-amount")
    field.set("12abc34")
    field.native.send_keys(:tab)

    assert_equal "12abc34", first("input.posting-amount").value
  end
end
