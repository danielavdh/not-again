# frozen_string_literal: true

require "test_helper"

# The flat-rate field was first added to reports/new.html.erb, which is not the
# form the dashboard opens — "+ Add Report" renders reports/_report-modal.
# So the field existed and was unreachable. This asserts it is on the form a
# user actually meets.
class ReportModalFlatRateTest < ActionDispatch::IntegrationTest
  setup do
    TaxSchemeConfig.reload!
    Dir[Rails.root.join("db/tax_categories/gb_*.yml")].each { |f| TaxCategoryLoader.call(f) }
    @entity = entities(:family_biz)
    sign_in_as(admins(:two))
  end

  def dashboard_body
    get dashboard_path(locale: :en)
    assert_response :success
    response.body
  end

  test "a VAT group's new-report form offers the flat rate" do
    patch update_tax_entity_path(@entity), params: { entity: { tax_schemes: [ "gb_vat" ] } }

    assert_match(/report\[flat_rate_percentage\]/, dashboard_body,
                 "the dashboard's Add Report form must carry the flat-rate field")
  end

  # Only a return with a line for it asks for a prepayment: the German UStVA
  # has Kz 39, the British VAT100 has nothing of the kind.
  test "a German VAT group's form asks for the Sondervorauszahlung, a British one does not" do
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/de_vat_2026.yml"))
    patch update_tax_entity_path(@entity), params: { entity: { tax_schemes: [ "de_vat" ] } }
    assert_match(/report\[prepayment_display\]/, dashboard_body)
    assert_match(/Sondervorauszahlung/, dashboard_body, "in the authority's own words")

    patch update_tax_entity_path(@entity), params: { entity: { tax_schemes: [ "gb_vat" ] } }
    assert_no_match(/report\[prepayment_display\]/, dashboard_body)
  end

  # An income-tax scheme has no flat rate, and offering one would invite a
  # number that silently changes nothing.
  test "a non-VAT group's form does not" do
    patch update_tax_entity_path(@entity), params: { entity: { tax_schemes: [ "gb_self_employment" ] } }

    assert_no_match(/report\[flat_rate_percentage\]/, dashboard_body)
  end
end
