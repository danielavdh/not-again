require "application_system_test_case"

# An entry's rows can only reach the entities of ONE family — postings_same_group
# refuses anything else. So the VAT column belongs on a form if ANY business in
# that family is registered, and nowhere else: showing it for every business the
# admin happens to run put it on forms where no row could ever use it.

class VatColumnScopeTest < ApplicationSystemTestCase
  test "the VAT column follows the family, not the admin's whole access" do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    sign_in_system(admins(:two))
    entities(:family_biz).update!(tax_schemes: [ "gb_vat" ])
    entities(:daughter).update!(tax_schemes: [])
    col = -> { page.evaluate_script("!!document.querySelector('th.tax-col')") }

    # Ungrouped first: leaving a family is refused once the two share entries,
    # which the fixtures do — joining one is always allowed.
    visit app_url("/en/accounts/#{accounts(:daughter_bank).id}/new_withdrawal")
    assert_not col.call, "C: unregistered and in no family — no column"

    visit app_url("/en/accounts/#{accounts(:bank_gbp).id}/new_withdrawal")
    assert col.call, "A: a registered business must show the column"

    group = EntityGroup.create!(name: "Fam")
    entities(:family_biz).update!(entity_group: group)
    entities(:daughter).update!(entity_group: group)
    visit app_url("/en/accounts/#{accounts(:daughter_bank).id}/new_withdrawal")
    assert col.call, "B: unregistered, but now in a registered business's family"
  end
end
