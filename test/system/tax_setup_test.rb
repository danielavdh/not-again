require "application_system_test_case"

# The tax setup page asks one question, and the answer decides what appears.
# None of it is visible to a controller test: the question is a confirm(), the
# picker arrives by fetch, and the whole point is that NOTHING about the tax
# setup is saved until the page's one Save.
#
# That last part is what this test holds. Two commit points broke it once
# already — two forms meant unticking a scheme and then clicking the nearer Save
# discarded the change while still saying "saved". A modal that saved the scheme
# would bring the same class of bug back, so the rule is checked by clicking,
# not by reading the code.
class TaxSetupTest < ApplicationSystemTestCase
  setup do
    @admin  = admins(:sudo)
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [])
    sign_in_system(@admin)
  end

  # confirm(), not a block on the page: a block further down can be walked past,
  # and you could then Save a return that files from the app with nobody to file
  # it for.
  test "ticking a filable scheme asks, naming the tax office" do
    visit_tax_setup

    message = accept_confirm { check "entity_tax_scheme_gb_property" }
    assert_match "HMRC", message
  end

  test "a scheme that only gets tagged and exported asks nothing" do
    visit_tax_setup
    check "entity_tax_scheme_de_euer"

    assert_no_selector "#add-taxpayer-modal[open]"
    assert_no_selector "#filing_hmrc_taxpayer_id"
  end

  test "saying no leaves the page as it was" do
    visit_tax_setup
    dismiss_confirm { check "entity_tax_scheme_gb_property" }

    assert_no_selector "#add-taxpayer-modal[open]"
    assert_no_selector "#filing_hmrc_taxpayer_id"
    assert_checked_field "entity_tax_scheme_gb_property"
  end

  # One login covers every scheme behind an authority, so two ticks are one
  # question. A second confirm here would leave the modal open and fail below.
  test "two schemes at one authority ask once" do
    @admin.taxpayers.create!(authority: "hmrc", label: "Laura")
    visit_tax_setup

    accept_confirm { check "entity_tax_scheme_gb_property" }
    assert_selector "#add-taxpayer-modal[open]"
    find("[data-taxpayer-use]").click

    check "entity_tax_scheme_gb_self_employment"
    assert_no_selector "#add-taxpayer-modal[open]"
  end

  # Saying yes opens the modal at once, so the setup is complete before you ever
  # reach Save.
  test "saying yes opens the chooser straight away" do
    @admin.taxpayers.create!(authority: "hmrc", label: "Laura")
    visit_tax_setup

    accept_confirm { check "entity_tax_scheme_gb_property" }

    assert_selector "#add-taxpayer-modal[open]"
    assert_selector "#choose_taxpayer_id"
    assert_selector "[data-taxpayer-new]", text: I18n.t("filing.register.add")
  end

  test "with nobody on file the chooser offers only adding" do
    visit_tax_setup
    accept_confirm { check "entity_tax_scheme_gb_property" }

    assert_selector "#add-taxpayer-modal[open]"
    assert_no_selector "#choose_taxpayer_id"

    find("[data-taxpayer-new]").click
    assert_selector "#taxpayer_identifiers_nino"
  end

  # Choosing writes nothing at all — it fills the picker on the page behind.
  test "choosing one fills the picker and saves nothing" do
    taxpayer = @admin.taxpayers.create!(authority: "hmrc", label: "Laura")
    visit_tax_setup
    accept_confirm { check "entity_tax_scheme_gb_property" }

    find("[data-taxpayer-use]").click

    assert_no_selector "#add-taxpayer-modal[open]"
    assert_equal taxpayer.id.to_s, find("#filing_hmrc_taxpayer_id").value
    assert_equal [], @entity.reload.tax_schemes
  end

  # Adding saves a TAXPAYER, which is a record of its own, and nothing about the
  # tax setup.
  test "adding one saves the taxpayer and still not the scheme" do
    visit_tax_setup
    accept_confirm { check "entity_tax_scheme_gb_property" }
    find("[data-taxpayer-new]").click

    fill_in "taxpayer[label]", with: "Laura"
    fill_in "taxpayer[identifiers][nino]", with: "AB123456C"
    click_on I18n.t("crud.create")

    assert_no_selector "#add-taxpayer-modal[open]"
    created = Taxpayer.order(:id).last
    assert_equal "Laura", created.label
    assert_equal created.id.to_s, find("#filing_hmrc_taxpayer_id").value
    assert_equal [], @entity.reload.tax_schemes
  end

  test "a bad number comes back as an error, with the modal still open" do
    visit_tax_setup
    accept_confirm { check "entity_tax_scheme_gb_property" }
    find("[data-taxpayer-new]").click

    fill_in "taxpayer[identifiers][nino]", with: "nonsense"
    click_on I18n.t("crud.create")

    assert_selector "#add-taxpayer-errors"
    assert_selector "#add-taxpayer-modal[open]"
    assert_equal 0, Taxpayer.count
  end

  # Save is what commits, and it commits everything at once.
  test "one Save commits the scheme and the taxpayer together" do
    taxpayer = @admin.taxpayers.create!(authority: "hmrc", label: "Laura")
    visit_tax_setup
    accept_confirm { check "entity_tax_scheme_gb_property" }
    find("[data-taxpayer-use]").click

    find("form#edit_tax_entity input[type=submit]").click

    assert_no_current_path app_url("/en/entities/#{@entity.id}/edit_tax"), wait: 5
    group = @entity.reload.report_groups.find_by(tax_scheme: "gb_property")
    assert_equal [ "gb_property" ], @entity.tax_schemes
    assert_equal taxpayer, group.taxpayer
  end

  # Unsubscribing releases the accounts. Left tagged, they belong to a return
  # this entity no longer files: no assign page lists them and no report reads
  # them.
  test "unsubscribing a scheme releases its accounts" do
    @entity.update!(tax_schemes: [ "gb_property" ])
    @entity.report_groups.create!(name: "gb_property", tax_scheme: "gb_property")
    account = Account.create!(code: "5#{@entity.code}901", name: "Ground rent",
                                   account_type: :expense, active: true,
                                   tax_scheme: "gb_property",
                                   tax_category_key: "rent_rates_insurance")

    visit_tax_setup
    uncheck "entity_tax_scheme_gb_property"
    find("form#edit_tax_entity input[type=submit]").click

    # Wait for the FLASH, not for the fieldset to go. Unticking removes the
    # fieldset client-side straight away (see "unticking one of two schemes"
    # below), so `assert_no_selector "#filing-fields fieldset"` is satisfied
    # before the form is even submitted — and the reload below then raced the
    # POST, passing or failing depending on which won. The flash only exists
    # after the server has redirected, which is exactly the point this test
    # needs to wait for.
    assert_selector ".flash", wait: 5

    account.reload
    assert_nil account.tax_scheme
    assert_nil account.tax_category_key
  end

  # Unticking on the page takes the authority block away at once — the tax setup
  # is fiddly enough without a fieldset sitting there for a scheme you just
  # cleared. Nothing is saved: Save and reload rebuild from the stored schemes.
  test "unticking a pending scheme removes its block without saving" do
    @admin.taxpayers.create!(authority: "hmrc", label: "Laura")
    visit_tax_setup

    accept_confirm { check "entity_tax_scheme_gb_property" }
    find("[data-taxpayer-use]").click
    assert_selector "#filing-fields fieldset"

    uncheck "entity_tax_scheme_gb_property"
    assert_no_selector "#filing-fields fieldset"
    assert_equal [], @entity.reload.tax_schemes
  end

  # ...but only when no other scheme of that authority is still ticked — one
  # login covers them all, so one block.
  test "unticking one of two schemes at an authority keeps the block" do
    @admin.taxpayers.create!(authority: "hmrc", label: "Laura")
    visit_tax_setup

    accept_confirm { check "entity_tax_scheme_gb_property" }
    find("[data-taxpayer-use]").click
    check "entity_tax_scheme_gb_self_employment"

    uncheck "entity_tax_scheme_gb_property"
    assert_selector "#filing-fields fieldset"
  end

  # The "choose a taxpayer above" line is rendered from the SAVED taxpayer, so
  # it has to be hidden the moment one is picked, or it sits there
  # contradicting the dropdown right above it.
  test "the choose-a-taxpayer line goes once one is picked" do
    @admin.taxpayers.create!(authority: "hmrc", label: "Laura")
    visit_tax_setup

    accept_confirm { check "entity_tax_scheme_gb_property" }
    assert_selector "[data-taxpayer-pending]", visible: true

    find("[data-taxpayer-use]").click
    assert_no_selector "[data-taxpayer-pending]", visible: true
  end

  private

  def visit_tax_setup
    visit app_url("/en/entities/#{@entity.id}/edit_tax")
    assert_selector "#filing-fields"
  end
end
