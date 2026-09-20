# frozen_string_literal: true
require "test_helper"

class ReportGroupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:two)
    @entity = entities(:family_biz)
    @group = ReportGroup.create!(name: "Controller Test Group", entity: @entity)
    sign_in_as(@admin)
  end

  # --- Show ---

  test "should show report group" do
    get report_group_url(@group, locale: :en)
    assert_response :success
  end

  test "cannot show report group from inaccessible entity" do
    other_entity = entities(:personal)
    other_group = ReportGroup.create!(name: "Private Group", entity: other_entity)
    get report_group_url(other_group, locale: :en)
    assert_response :not_found
  end

  # --- Create ---

  test "should create report group" do
    assert_difference("ReportGroup.count") do
      post entity_report_groups_url(@entity, locale: :en), params: {
        report_group: { name: "New Group" }
      }
    end
    assert_redirected_to dashboard_path
  end

  test "cannot create group for inaccessible entity" do
    other_entity = entities(:personal)
    post entity_report_groups_url(other_entity, locale: :en), params: {
      report_group: { name: "Hack" }
    }
    assert_response :not_found
  end

  # --- Edit / Update ---

  test "should get edit" do
    get edit_report_group_url(@group, locale: :en)
    assert_response :success
  end

  test "should update report group" do
    patch report_group_url(@group, locale: :en), params: {
      report_group: { name: "Renamed Group" }
    }
    assert_redirected_to report_group_url(@group, locale: :en)
    @group.reload
    assert_equal "Renamed Group", @group.name
  end

  test "update fails without name" do
    patch report_group_url(@group, locale: :en), params: {
      report_group: { name: "" }
    }
    assert_response :unprocessable_entity
  end

  # --- update_accounts ---

  test "update_accounts replaces accounts via JSON" do
    account = accounts(:income_sales)
    patch update_accounts_report_group_url(@group, locale: :en, format: :json), params: {
      accounts: [{ id: account.id, position: 1 }]
    }
    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert_equal 1, json["count"]
    assert_includes @group.reload.account_ids_ordered, account.id
  end

  test "update_accounts with empty list clears accounts" do
    account = accounts(:income_sales)
    @group.update_accounts([[account.id, 1]])
    patch update_accounts_report_group_url(@group, locale: :en, format: :json), params: {
      accounts: []
    }
    assert_response :success
    assert_equal [], @group.reload.account_ids_ordered
  end

  # --- Destroy ---

  test "should destroy report group" do
    assert_difference("ReportGroup.count", -1) do
      delete report_group_url(@group, locale: :en)
    end
    assert_redirected_to dashboard_path
  end

  # A tax report group belongs to its scheme while the entity is subscribed.
  test "a tax report group cannot be deleted while its scheme is subscribed" do
    @entity.update!(tax_schemes: [ "gb_self_employment" ])
    tax_group = ReportGroup.create!(name: "gb_self_employment", entity: @entity,
                                         tax_scheme: "gb_self_employment")
    assert_no_difference("ReportGroup.count") do
      delete report_group_url(tax_group, locale: :en)
    end
    assert_redirected_to dashboard_path
  end

  # Once unsubscribed it is left standing — the reports under it are the admin's
  # to keep or discard — but an empty one may then be cleared away.
  test "an unsubscribed tax report group with no reports can be deleted" do
    @entity.update!(tax_schemes: [])
    tax_group = ReportGroup.create!(name: "gb_self_employment", entity: @entity,
                                         tax_scheme: "gb_self_employment")
    assert_difference("ReportGroup.count", -1) do
      delete report_group_url(tax_group, locale: :en)
    end
  end

  # EntitiesController releases accounts on unsubscribe, but deleting the group
  # directly used to skip that entirely — leaving accounts tagged to a scheme
  # nothing pointed at any more, invisible to both the assign page, whose group
  # is gone, and unmapped_for_tax, whose key is not blank.
  test "deleting a tax report group releases its accounts, not just the group" do
    @entity.update!(tax_schemes: [])
    tax_group = ReportGroup.create!(name: "gb_self_employment", entity: @entity,
                                         tax_scheme: "gb_self_employment")
    account = Account.create!(code: "5#{@entity.code}901", name: "Tagged", account_type: :expense,
                                   active: true,
                                   tax_scheme: "gb_self_employment", tax_category_key: "travel_costs")

    delete report_group_url(tax_group, locale: :en)

    account.reload
    assert_nil account.tax_scheme
    assert_nil account.tax_category_key
  end

  test "an unsubscribed tax report group holding reports is kept" do
    @entity.update!(tax_schemes: [])
    tax_group = ReportGroup.create!(name: "gb_self_employment", entity: @entity,
                                         tax_scheme: "gb_self_employment")
    tax_group.reports.create!(name: "2026", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 12, 31))

    assert_no_difference("ReportGroup.count") do
      delete report_group_url(tax_group, locale: :en)
    end
  end

  test "a tax report group cannot be edited or renamed" do
    tax_group = ReportGroup.create!(name: "gb_self_employment", entity: @entity,
                                         tax_scheme: "gb_self_employment")
    get report_group_url(tax_group, locale: :en) + "/edit"
    assert_redirected_to report_group_path(tax_group, locale: :en)

    patch report_group_url(tax_group, locale: :en),
          params: { report_group: { name: "renamed by hand" } }
    assert_redirected_to report_group_path(tax_group, locale: :en)
    assert_equal "gb_self_employment", tax_group.reload.name
  end

  test "a custom group can still be deleted when it has no reports" do
    assert_difference("ReportGroup.count", -1) do
      delete report_group_url(@group, locale: :en)
    end
  end

  # A tax report's page IS the assignment page: its accounts are whatever
  # carries
  # its scheme, so tagging is the only thing there is to do there.
  test "a tax report page offers unassigned accounts and lists assigned ones" do
    # Both filed, with the group each subscription would have created — a group
    # is what claims an account, so "claimed elsewhere" below means claimed by a
    # return this entity really does file. That case must stay out of this list.
    @entity.update!(tax_schemes: %w[gb_self_employment gb_property])
    @entity.report_groups.find_or_create_by!(tax_scheme: "gb_property") { |g| g.name = "gb_property" }
    tax_group = ReportGroup.create!(name: "gb_self_employment", entity: @entity,
                                         tax_scheme: "gb_self_employment")
    TaxCategory.find_or_create_by!(country_code: "gb", scheme: "gb_self_employment",
                                        tax_year: 2026, key: "travel_costs") do |c|
      c.section = "expenses"
      c.position = 10
    end

    code   = @entity.code
    tagged = Account.create!(code: "5#{code}801", name: "Tagged", account_type: :expense,
                                  active: true,
                                  tax_scheme: "gb_self_employment", tax_category_key: "travel_costs")
    free   = Account.create!(code: "5#{code}802", name: "Free", account_type: :expense,
                                  active: true)
    # claimed by ANOTHER scheme — an account is in exactly one, so it must not
    # be offered
    other  = Account.create!(code: "5#{code}803", name: "Elsewhere", account_type: :expense,
                                  active: true,
                                  tax_scheme: "gb_property", tax_category_key: "travel_costs")

    get report_group_url(tax_group, locale: :en)
    assert_response :success

    assert_select "[data-account-row=?]", tagged.id.to_s
    assert_select "[data-account-row=?]", free.id.to_s
    assert_select "[data-account-row=?]", other.id.to_s, count: 0

    # nothing to save or edit — assignment writes as you go
    assert_select ".save-accounts", count: 0
    assert_select "a", text: /#{Regexp.escape(I18n.t("crud.edit"))}/, count: 0
  end

  # NO SAVE BUTTON: this screen writes as you go, like the tax one beside it.
  # The two looked the same and behaved differently, and walking away from a
  # long selection lost it.
  #
  # What replaces the button is the status element, which carries the URL and
  # its own wording as data attributes — the script must hold no English, or the
  # message stays English in every language.
  test "a custom report group has the picker and saves as you go" do
    get report_group_url(@group, locale: :en)
    assert_response :success

    assert_select ".sortable-list", 1, "the hand-ordered picker is still here"
    assert_select ".save-accounts", { count: 0 }, "but nothing to press"
    assert_select ".save-status[data-url][data-saving][data-saved][data-failed]", 1
    assert_select "[data-tax-mapping]", count: 0
  end

  test "a tax report group shows its declared name, not the stored slug" do
    tax_group = ReportGroup.create!(name: "gb_self_employment", entity: @entity,
                                         tax_scheme: "gb_self_employment")
    get report_group_url(tax_group, locale: :en)
    assert_response :success
    assert_match "GB-self-employment", response.body
  end

  # The button sat inside the "has reports" branch, so a group with none showed
  # "no reports" and no way to make one. Tax groups are always created empty,
  # which made it look like a rule about them — an empty custom group had
  # exactly the same problem.
  test "a group with no reports still offers a way to add one" do
    assert_empty @group.reports

    get report_group_url(@group, locale: :en)
    assert_response :success
    assert_select "[data-modal=?]", "reportModal-#{@group.id}"
  end

  test "and so does a tax report group, which always starts empty" do
    tax = ReportGroup.create!(name: "GB-self-employment", entity: @entity,
                                   tax_scheme: "gb_self_employment")
    assert_empty tax.reports

    get report_group_url(tax, locale: :en)
    assert_response :success
    assert_select "[data-modal=?]", "reportModal-#{tax.id}"
  end

  # --- Unauthenticated ---

  test "unauthenticated cannot access report group" do
    sign_out
    get report_group_url(@group, locale: :en)
    assert_response :redirect
  end
end
