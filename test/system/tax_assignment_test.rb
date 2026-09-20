require "application_system_test_case"

# The assignment page is almost entirely JavaScript: a row crosses between the
# two lists without a page load, the counters move with it, the control swaps
# from + to ×, and the box's wording appears under whichever select you touch.
# None of that is visible to a controller test, which sees the markup the server
# sent and nothing that happened afterwards.
#
# Every bug found in this page so far was found by clicking: the row that never
# crossed because save() ended in closest('tr') on an <li>; the button that came
# back unstyled because the JS built it without its class; the account that
# vanished from one list without appearing in the other.
class TaxAssignmentTest < ApplicationSystemTestCase
  setup do
    @admin  = admins(:two)
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "gb_self_employment" ])

    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_self_employment_2026.yml"))

    @group = @entity.report_groups.find_or_create_by!(tax_scheme: "gb_self_employment") do |g|
      g.name = "gb_self_employment"
    end

    code = @entity.code
    @assigned = Account.create!(code: "5#{code}811", name: "Already sorted",
                                     account_type: :expense, active: true,
                                     tax_scheme: "gb_self_employment",
                                     tax_category_key: "travel_costs")
    @free     = Account.create!(code: "5#{code}812", name: "Needs a category",
                                     account_type: :expense, active: true)

    sign_in_system(@admin)
  end

  test "adding an account moves it across to the assigned list" do
    visit_group

    assert_selector "ul.tax-unassigned li[data-account-row='#{@free.id}']"
    # Relative, not absolute: the fixtures carry their own untagged accounts,
    # and
    # what matters is that both counters move by one when a row crosses.
    remaining_before = count_in("[data-tax-remaining]")
    assigned_before  = count_in("[data-tax-assigned-count]")

    within "li[data-account-row='#{@free.id}']" do
      select_a_category "30 — Other business expenses"
      click_button "+"
    end

    # Capybara waits for these, so they assert the JS actually ran.
    assert_selector "ul.tax-assigned li[data-account-row='#{@free.id}']"
    assert_no_selector "ul.tax-unassigned li[data-account-row='#{@free.id}']"
    assert_equal remaining_before - 1, count_in("[data-tax-remaining]")
    assert_equal assigned_before + 1, count_in("[data-tax-assigned-count]")

    # …and it was really saved, not just moved on screen.
    assert_equal "other_expenses", @free.reload.tax_category_key
    assert_equal "gb_self_employment", @free.tax_scheme
  end

  test "a row that crosses gets the right control for its new side" do
    visit_group

    within "li[data-account-row='#{@free.id}']" do
      select_a_category "30 — Other business expenses"
      click_button "+"
    end

    within "ul.tax-assigned li[data-account-row='#{@free.id}']" do
      # × to release it, styled like the one the server renders.
      assert_selector "button.remove-account[data-tax-unassign]"
      assert_no_selector "button.add-account"
    end
  end

  test "releasing an account sends it back to the unassigned list" do
    visit_group

    within "ul.tax-assigned li[data-account-row='#{@assigned.id}']" do
      click_button "×"
    end

    assert_selector "ul.tax-unassigned li[data-account-row='#{@assigned.id}']"
    assert_no_selector "ul.tax-assigned li[data-account-row='#{@assigned.id}']"

    within "ul.tax-unassigned li[data-account-row='#{@assigned.id}']" do
      assert_selector "button.add-account[data-tax-confirm]"
    end

    # Released on both fields, so another scheme may claim it.
    @assigned.reload
    assert_nil @assigned.tax_category_key
    assert_nil @assigned.tax_scheme
  end

  test "changing an assigned account's category saves in place" do
    visit_group

    within "ul.tax-assigned li[data-account-row='#{@assigned.id}']" do
      select_a_category "23 — Phone, fax, stationery and other office costs"
    end

    # Still on the assigned side — only the category changed.
    assert_selector "ul.tax-assigned li[data-account-row='#{@assigned.id}']"
    assert_equal "admin_costs", reload_until(@assigned) { |a| a.tax_category_key == "admin_costs" }
  end

  test "the box's own wording appears under the select you touch, and only there" do
    visit_group

    within "li[data-account-row='#{@free.id}']" do
      # A category that carries a note in the catalogue.
      select_a_category "24 — Advertising costs"
      assert_selector "p.tax-note", text: /business entertainment/i
    end

    # The other rows were not touched, so they say nothing.
    assert_selector "p.tax-note", count: 1
  end

  # Most categories need no explanation — the label is the box. Those must not
  # leave an empty line hanging under the select.
  test "a category with nothing to explain shows no note" do
    visit_group

    within "li[data-account-row='#{@free.id}']" do
      select_a_category "21 — Rent, rates, power and insurance costs"
      assert_no_selector "p.tax-note"
    end
  end

  # The auto-assigner pre-fills a guess where the account code allows one, and
  # clicking + confirms whatever is in the select — that IS the confirmation
  # step. With the guess cleared there is nothing to confirm, so + does nothing.
  test "nothing is saved when no category is selected" do
    visit_group

    within "li[data-account-row='#{@free.id}']" do
      select_a_category t_none
      click_button "+"
    end

    assert_selector "ul.tax-unassigned li[data-account-row='#{@free.id}']"
    assert_nil @free.reload.tax_category_key
  end

  private

  def count_in(selector)
    find(selector).text.to_i
  end

  def t_none
    I18n.t("tax.category_none")
  end

  def visit_group
    visit app_url("/en/report_groups/#{@group.id}")
    assert_selector "[data-tax-mapping]"
  end

  # The select is a native one carrying grouped options labelled
  # "<reference> — <label>", e.g. "21 — Rent, rates, power and insurance costs".
  def select_a_category(option_text)
    find("select[data-tax-note]").select(option_text)
  end

  # The PATCH is fire-and-forget from the browser's point of view, so give the
  # server a moment rather than asserting on a race.
  def reload_until(record, attempts: 20)
    attempts.times do
      record.reload
      break if yield(record)
      sleep 0.05
    end
    record.tax_category_key
  end

end
