# frozen_string_literal: true

require "test_helper"

# Subscribing to an income-tax scheme leaves a job to do — assign the accounts
# — so it lands on the page where that is done. A VAT scheme leaves no such
# job: its boxes come from the codes on postings, so it lands on the dashboard.
class EntitiesTaxSetupVatTest < ActionDispatch::IntegrationTest
  setup do
    TaxSchemeConfig.reload!
    Dir[Rails.root.join("db/tax_categories/gb_*.yml")].each { |f| TaxCategoryLoader.call(f) }
    @entity = entities(:family_biz)
    sign_in_as(admins(:two))
  end

  def tick(*schemes)
    patch update_tax_entity_path(@entity), params: { entity: { tax_schemes: schemes } }
  end

  test "ticking VAT alone lands on the dashboard, not on an assignment page" do
    tick "gb_vat"

    assert_redirected_to dashboard_path
    assert_no_match(/assign/i, flash[:notice].to_s,
                    "there are no accounts to assign to a VAT return")
  end

  test "ticking an income-tax scheme still lands on its own page" do
    tick "gb_self_employment"

    group = @entity.report_groups.find_by(tax_scheme: "gb_self_employment")
    assert_redirected_to report_group_path(group)
  end

  # Both at once: the income-tax scheme is the one with work outstanding, so
  # that is where to land — never whichever happened to come first.
  test "ticking both lands on the income-tax scheme" do
    tick "gb_vat", "gb_self_employment"

    group = @entity.report_groups.find_by(tax_scheme: "gb_self_employment")
    assert_redirected_to report_group_path(group)
  end

  test "ticking VAT still creates its report group, so the dashboard has a row" do
    tick "gb_vat"

    group = @entity.report_groups.find_by(tax_scheme: "gb_vat")
    assert group, "the group is what carries the return and its periods"
    assert group.vat_report?
  end
end
