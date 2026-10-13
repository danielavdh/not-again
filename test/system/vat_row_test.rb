require "application_system_test_case"

# The VAT cell is the one place the user sees the split before it is saved: pick
# a code, the VAT field appears with the figure the rate works out to, and the
# net shows what will actually hit the P&L. All of that happens in the browser,
# so nothing below it can tell whether it works.
#
# The arithmetic itself is asserted against the SERVER's answer, because the
# whole point of mirroring the rounding in JS is that the two agree.
#
# Showing and hiding is asserted on the .hidden CLASS, not on visibility: the
# JS's job is to toggle the class, and whether that class wins against the
# cell's own styling is the stylesheet's.
class VatRowTest < ApplicationSystemTestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    entities(:family_biz).update!(tax_schemes: [ "gb_vat" ])
    sign_in_system(admins(:two))
  end

  def row = first("tr.posting-row")

  # The account select's look comes from TomSelect; the VAT select declares the
  # same thing, so it must actually be wrapped by it and not just carry a dead
  # attribute.
  test "the VAT select is a TomSelect, like the account select beside it" do
    visit app_url("/en/journal_entries/new")

    within(row) do
      assert_selector ".posting-account.tomselected", visible: :all
      assert_selector ".posting-tax-code.tomselected", visible: :all
      assert_selector "td.tax-col .ts-wrapper"
    end
  end

  # TomSelect sorts alphabetically by default, which silently threw away the
  # catalogue's own order — commonest rates first. The list must read in the
  # order the server sent it.
  test "the codes keep the catalogue's order, not alphabetical" do
    visit app_url("/en/journal_entries/new")

    within(row) { find("td.tax-col .ts-control").click }
    # The blank "no VAT" option leads, as include_blank puts it; the codes
    # follow in the catalogue's order.
    shown = all(".ts-dropdown .option", minimum: 3).map(&:text).drop(1)

    assert_equal "Standard rate (20%)", shown.first,
                 "commonest first, not whatever sorts to the top"
    assert_operator shown.index("Standard rate (20%)"),
                    :<,
                    shown.index { |t| t.include?("Reverse charge") },
                    "the everyday rates come before the odd ones"
  end

  test "a business with no VAT scheme sees no VAT column at all" do
    entities(:family_biz).update!(tax_schemes: [])
    visit app_url("/en/journal_entries/new")

    assert_no_selector "select.posting-tax-code"
  end

  test "picking a code reveals the VAT it works out to, and the net" do
    visit app_url("/en/journal_entries/new")

    assert_selector "select.posting-tax-code"
    within(row) { assert_selector ".tax-figures.hidden", visible: :all }

    within(row) do
      fill_in_amount "120.00"
      select_code "purchase_standard"

      assert_no_selector ".tax-figures.hidden", visible: :all
      assert_equal "20.00", find("input.posting-tax-amount").value
      assert_text "100.00"
    end
  end

  # 100.00 gross at 20% is 16.67 of VAT, not 20.00 — the rate comes OUT of the
  # gross. The server computes the same figure; tax_code_test holds that half.
  test "the VAT comes out of the gross, not on top of it" do
    visit app_url("/en/journal_entries/new")

    within(row) do
      fill_in_amount "100.00"
      select_code "purchase_standard"

      assert_equal "16.67", find("input.posting-tax-amount").value
      assert_text "83.33"
    end
  end

  test "changing the gross recomputes the VAT" do
    visit app_url("/en/journal_entries/new")

    within(row) do
      fill_in_amount "120.00"
      select_code "purchase_standard"
      assert_equal "20.00", find("input.posting-tax-amount").value

      fill_in_amount "240.00"
      assert_equal "40.00", find("input.posting-tax-amount").value
    end
  end

  # An invoice that rounded differently from us. The typed figure stands.
  test "a typed VAT figure survives until the gross changes" do
    visit app_url("/en/journal_entries/new")

    within(row) do
      fill_in_amount "118.99"
      select_code "purchase_standard"
      field = find("input.posting-tax-amount")

      field.set("18.99")
      field.native.send_keys(:tab)
      assert_equal "18.99", field.value
      assert_text "100.00"

      fill_in_amount "120.00"
      assert_equal "20.00", field.value, "a new gross is a new sum, so ours is shown again"
    end
  end

  test "clearing the code hides the VAT field again" do
    visit app_url("/en/journal_entries/new")

    within(row) do
      fill_in_amount "120.00"
      select_code "purchase_standard"
      assert_no_selector ".tax-figures.hidden", visible: :all

      # By value, not by label: the blank option's wording is a pending
      # translation and would read "translation missing" here.
      find("select.posting-tax-code").find("option[value='']").select_option
      assert_selector ".tax-figures.hidden", visible: :all
    end
  end

  # Reverse charge adds VAT rather than carving it out: the invoice carried
  # none, so the net is the whole amount.
  test "reverse charge leaves the net equal to the gross" do
    visit app_url("/en/journal_entries/new")

    within(row) do
      fill_in_amount "100.00"
      select_code "purchase_reverse_charge"

      assert_equal "20.00", find("input.posting-tax-amount").value
      # The net equals the gross: nothing was carved out of it.
      assert_text "100.00"
    end
  end

  # A 70% business use of a 120.00 VAT invoice: HMRC lets you reclaim 70% of the
  # 20.00, i.e. 14.00, and the other 6.00 is part of the private cost. Splitting
  # the GROSS 70/30 and deriving each row's own VAT gives exactly that — but
  # only if the VAT figure is recomputed when the split rewrites the amount.
  test "splitting a VAT invoice recomputes the VAT on the business share" do
    visit app_url("/en/accounts/#{accounts(:bank_gbp).id}/new_withdrawal")

    within(row) do
      fill_in_amount "120.00"
      select_code "purchase_standard"
      assert_equal "20.00", find("input.posting-tax-amount").value
    end

    first("button.split-btn").click
    within("#split-modal") do
      select accounts(:expenses_general).name, from: "split-account-1"
      fill_in "split-percentage", with: "70"
      select accounts(:personal_drawings).name, from: "split-account-2"
      click_button "Apply"
    end

    within(row) do
      assert_equal "84.00", find("input.posting-amount").value
      assert_equal "14.00", find("input.posting-tax-amount").value,
                   "70% of the VAT, not the whole 20.00"
      assert_text "70.00"
    end
  end

  # The whole point of remembering: pick the account, and the code it was last
  # used with is already there. Most rows then need no VAT decision at all.
  test "choosing an account offers the code it was last used with" do
    code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_reduced", on: Date.current)
    accounts(:expenses_general).update!(default_tax_code: code)
    visit app_url("/en/journal_entries/new")

    within(row) do
      select_account accounts(:expenses_general)
      fill_in_amount "105.00"

      assert_no_selector ".tax-figures.hidden", visible: :all
      assert_equal "5.00", find("input.posting-tax-amount").value, "5% of a gross 105.00"
    end
  end

  # Picking a code teaches the account, so the next entry on it starts there.
  test "picking a code is remembered on the account" do
    assert_nil accounts(:expenses_general).default_tax_code_id
    visit app_url("/en/journal_entries/new")

    within(row) do
      select_account accounts(:expenses_general)
      select_code "purchase_reduced"
    end

    # The save-back is a fetch, so it lands after the click returns. Capybara
    # waits on the DOM, not on the database, so this waits explicitly rather
    # than reading a value that may not be there yet.
    assert_equal "purchase_reduced", eventually {
      accounts(:expenses_general).reload.default_tax_code&.key
    }
  end

  # Never over the top of a choice already made.
  test "a code already chosen is not replaced by the account's default" do
    code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_reduced", on: Date.current)
    accounts(:expenses_general).update!(default_tax_code: code)
    visit app_url("/en/journal_entries/new")

    within(row) do
      select_code "purchase_standard"
      select_account accounts(:expenses_general)
      fill_in_amount "120.00"

      assert_equal "20.00", find("input.posting-tax-amount").value, "the chosen 20% stands"
    end
  end

  private

  # Polls for a value the browser writes through an async request. Bounded, and
  # returns whatever it last saw so the failure message is the real value.
  def eventually(within: 5)
    deadline = Time.now + within
    loop do
      value = yield
      return value if value || Time.now > deadline
      sleep 0.05
    end
  end

  def select_account(account)
    select "#{account.code} - #{account.name}", from: find("select.posting-account")[:name]
  end

  def fill_in_amount(value)
    field = find("input.posting-amount")
    field.set(value)
    field.native.send_keys(:tab)
  end

  # By KEY, not by label. "Reduced rate (5%)" now reads identically in both
  # groups — the optgroup heading is what tells a reader which, and a screen
  # reader announces it, but option text alone no longer identifies a code. It
  # also means renaming a label cannot break these tests.
  def select_code(key)
    code = TaxCode.resolve(scheme: "gb_vat", key: key, on: Date.current)
    assert code, "no gb_vat code #{key} in force today"
    find("select.posting-tax-code").find("option[value='#{code.id}']").select_option
  end
end
