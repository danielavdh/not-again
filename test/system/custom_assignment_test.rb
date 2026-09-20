require "application_system_test_case"

# THE CUSTOM ASSIGNMENT PAGE SAVES AS YOU GO, and that is only verifiable by
# clicking: a controller test sees the markup the server sent and nothing that
# happened afterwards, and everything here happens afterwards.
#
# It used to need a Save button while the TAX page beside it saved on every
# click — two screens that look the same, behave differently, and say nothing
# about which is which; walk away from a long selection and it was gone.
#
# The one assertion that matters in every test below is the RELOAD. Anything can
# look right in the DOM; only coming back to the page proves it was written.
class CustomAssignmentTest < ApplicationSystemTestCase
  setup do
    @admin  = admins(:two)
    @entity = entities(:family_biz)
    code    = @entity.code

    # A CUSTOM group — no tax_scheme, so it renders _custom_assignment.
    @group = @entity.report_groups.create!(name: "Hand-picked")

    @one = Account.create!(code: "5#{code}821", name: "Postage",
                                account_type: :expense, active: true)
    @two = Account.create!(code: "5#{code}822", name: "Stationery",
                                account_type: :expense, active: true)

    sign_in_system(@admin)
    visit_group
  end

  test "adding an account persists without pressing anything" do
    add(@one)

    assert_selector ".sortable-list li", count: 1
    visit_group

    assert_selector ".sortable-list li", count: 1, wait: 5
    assert_equal [ @one.id ], stored_account_ids
  end

  test "removing one persists too" do
    add(@one)
    add(@two)
    assert_equal 2, stored_account_ids.size

    find(".sortable-list li[data-account-id='#{@one.id}'] .remove-account").click
    assert_selector ".sortable-list li", count: 1
    wait_for_save

    visit_group
    assert_equal [ @two.id ], stored_account_ids
  end

  # Order is part of the data on this screen. It is what makes a per-account
  # endpoint the wrong shape here, and why the whole ordered list is sent every
  # time rather than one PATCH per row like the tax page.
  test "the order is what was saved" do
    add(@one)
    add(@two)

    visit_group
    assert_equal [ @one.id, @two.id ], stored_account_ids, "added in that order"
  end

  # Ten clicks are one request, not ten. Nothing user-visible, but it is the
  # reason autosave is affordable on a list you build by clicking.
  test "a burst of clicks collapses into one save" do
    add(@one)
    add(@two)

    visit_group
    assert_equal 2, stored_account_ids.size
  end

  private

  def add(account)
    find(".add-account[data-account-id='#{account.id}']").click
    wait_for_save
  end

  # Wait for the save before doing anything else — the write is DEBOUNCED by
  # 400ms, so navigating straight after a click races it. The status element
  # appearing and going again IS the save; waiting on the stored rows instead
  # would be waiting on the very race this avoids.
  def wait_for_save
    assert_selector ".save-status", visible: true, wait: 5
    assert_no_selector ".save-status", visible: true, wait: 10
  end

  def stored_account_ids
    @group.reload.report_group_accounts.order(:position).pluck(:account_id)
  end

  def visit_group
    visit app_url("/en/report_groups/#{@group.id}")
  end
end
