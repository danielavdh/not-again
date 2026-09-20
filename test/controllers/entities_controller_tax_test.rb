# frozen_string_literal: true
require "test_helper"

class EntitiesControllerTaxTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(admins(:sudo))
  end

  # Subscribing through the controller, because that is what creates the tax
  # report groups — and the groups are what the filing details attach to.
  def subscribed(code, name, schemes)
    entity = Entity.create!(code: code, name: name, active: true)
    patch update_tax_entity_path(entity, locale: :en),
          params: { entity: { tax_schemes: [ "" ] + schemes } }
    entity.reload
  end

  # Stands in for the authority's business list, so no test makes a real call.
  def with_businesses(map)
    filing = Object.new
    filing.define_singleton_method(:businesses_by_scheme) { map }
    Filing::Base.stub(:for, filing) { yield }
  end

  def connected_taxpayer
    admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me",
                                    access_token: "tok", token_expires_at: 1.hour.from_now)
  end

  def save_filing(entity, taxpayer, business_id)
    patch update_tax_entity_path(entity, locale: :en), params: {
      entity: { tax_schemes: [ "", "gb_self_employment" ] },
      filing: { "hmrc" => { taxpayer_id: taxpayer.id,
                            business_ids: { "gb_self_employment" => business_id } } }
    }
  end

  # Its own entity: code 71 is created by another test in this file, not a
  # fixture.
  def tax_entity
    @tax_entity ||= Entity.create!(code: "80", name: "Tax Group Test", active: true)
  end

  test "can set tax_schemes" do
    post entities_path(locale: :en), params: {
      entity: { code: "71", name: "GB One", active: true,
                    tax_schemes: ["", "gb_self_employment", "gb_property"] }
    }
    assert_response :redirect
    e = Entity.find_by!(code: "71")
    assert_equal %w[gb_self_employment gb_property], e.tax_schemes
  end

  # A tax report group appears the moment a scheme is subscribed to, so the
  # accounts assigned to it have somewhere to be seen.
  test "subscribing to a scheme creates its tax report group" do
    entity = tax_entity

    patch update_tax_entity_path(entity, locale: :en), params: {
      entity: { tax_schemes: %w[gb_self_employment gb_property] }
    }

    groups = entity.reload.report_groups.tax_reports.order(:tax_scheme)
    assert_equal %w[gb_property gb_self_employment], groups.map(&:tax_scheme)
    assert_equal [ "GB-property", "GB-self-employment" ], groups.map(&:display_name)
  end

  test "re-saving the same schemes does not duplicate the groups" do
    entity = tax_entity
    2.times do
      patch update_tax_entity_path(entity, locale: :en), params: {
        entity: { tax_schemes: %w[gb_self_employment] }
      }
    end
    assert_equal 1, entity.reload.report_groups.tax_reports.where(tax_scheme: "gb_self_employment").count
  end

  # Reports (date ranges) live under the group, so unsubscribing must not throw
  # them away silently — the admin decides. See plan §4.10.
  test "unsubscribing leaves a group that has reports" do
    entity = tax_entity
    patch update_tax_entity_path(entity, locale: :en), params: {
      entity: { tax_schemes: %w[gb_self_employment] }
    }
    group = entity.reload.report_groups.tax_reports.find_by(tax_scheme: "gb_self_employment")
    group.reports.create!(name: "Q1", start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5))

    patch update_tax_entity_path(entity, locale: :en), params: {
      entity: { tax_schemes: [] }
    }
    assert entity.reload.report_groups.tax_reports.exists?(tax_scheme: "gb_self_employment"),
           "a group with reports survives unsubscribing"
  end

  # …but one that never produced a report is clutter, and goes with the scheme.
  test "unsubscribing discards a group that has no reports" do
    entity = tax_entity
    patch update_tax_entity_path(entity, locale: :en), params: {
      entity: { tax_schemes: %w[gb_self_employment] }
    }
    assert entity.reload.report_groups.tax_reports.exists?(tax_scheme: "gb_self_employment")

    patch update_tax_entity_path(entity, locale: :en), params: {
      entity: { tax_schemes: [] }
    }
    refute entity.reload.report_groups.tax_reports.exists?(tax_scheme: "gb_self_employment")
  end

  # A scheme from another country is fine — the scheme names its own country,
  # and an entity may file in more than one. Only an unknown slug is rejected.
  test "accepts a scheme from another country" do
    post entities_path(locale: :en), params: {
      entity: { code: "72", name: "X", active: true, tax_schemes: ["de_euer"] }
    }
    assert_response :redirect
    assert_equal ["de_euer"], Entity.find_by!(code: "72").tax_schemes
  end

  test "rejects a scheme that is not in the catalogue" do
    post entities_path(locale: :en), params: {
      entity: { code: "74", name: "Z", active: true, tax_schemes: ["no_such_scheme"] }
    }
    assert_response :unprocessable_entity
  end

  test "blank sentinel is stripped" do
    post entities_path(locale: :en), params: {
      entity: { code: "73", name: "Y", active: true, tax_schemes: [""] }
    }
    assert_response :redirect
    assert_equal [], Entity.find_by!(code: "73").tax_schemes
  end

  # The taxpayer and the business identifier belong to the tax report GROUP, not
  # to the entity: one taxpayer may keep several sets of books, and one set of
  # books may serve several authorities.
  test "the chosen taxpayer and business id land on the tax report group" do
    e = subscribed("75", "GB Two", %w[gb_self_employment])
    r = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me")

    patch update_tax_entity_path(e, locale: :en), params: {
      entity: { tax_schemes: [ "", "gb_self_employment" ] },
      filing: { "hmrc" => { taxpayer_id: r.id,
                            business_ids: { "gb_self_employment" => " XBIS1 " } } }
    }

    group = e.report_groups.find_by(tax_scheme: "gb_self_employment")
    assert_equal r,       group.taxpayer
    assert_equal "XBIS1", group.business_id
  end

  # Another admin's taxpayer must not be attachable by guessing an id.
  test "a taxpayer belonging to someone else is ignored" do
    e     = subscribed("77", "GB Four", %w[gb_self_employment])
    other = admins(:two).taxpayers.create!(authority: "hmrc", label: "Not mine")

    patch update_tax_entity_path(e, locale: :en), params: {
      entity: { tax_schemes: [ "", "gb_self_employment" ] },
      filing: { "hmrc" => { taxpayer_id: other.id } }
    }

    assert_nil e.report_groups.find_by(tax_scheme: "gb_self_employment").taxpayer
  end

  # One taxpayer per authority: every group behind HMRC gets the same one.
  test "all of an authority's groups share the chosen taxpayer" do
    e = subscribed("78", "GB Both", %w[gb_self_employment gb_property])
    r = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me")

    patch update_tax_entity_path(e, locale: :en), params: {
      entity: { tax_schemes: [ "", "gb_self_employment", "gb_property" ] },
      filing: { "hmrc" => { taxpayer_id: r.id,
                            business_ids: { "gb_self_employment" => "XBIS1",
                                            "gb_property"     => "XPIS1" } } }
    }

    groups = e.report_groups.where.not(tax_scheme: nil).index_by(&:tax_scheme)
    assert_equal [ r, r ], groups.values.map(&:taxpayer)
    assert_equal "XBIS1", groups["gb_self_employment"].business_id
    assert_equal "XPIS1", groups["gb_property"].business_id
  end

  # One block per AUTHORITY, not per scheme: permission is per authority, so two
  # blocks would print the same connection state twice and offer two Disconnect
  # buttons that do one thing.
  test "two schemes at one authority produce one connection block" do
    e = subscribed("79", "GB Both Blocks", %w[gb_self_employment gb_property])
    r = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me",
                                            access_token: "tok",
                                            token_expires_at: 1.hour.from_now)
    e.report_groups.where.not(tax_scheme: nil).each { |g| g.update!(taxpayer: r) }

    get edit_tax_entity_path(e, locale: :en)
    assert_response :success

    assert_select "section#gb_connection", count: 1
    assert_select "select[name=?]", "filing[hmrc][taxpayer_id]", count: 1
    # …but a business id field for each of the two trades.
    assert_select "input[name=?]", "filing[hmrc][business_ids][gb_self_employment]"
    assert_select "input[name=?]", "filing[hmrc][business_ids][gb_property]"
    assert_select "form[action=?]",
                  filing_disconnect_entity_path(e, locale: :en, connector: "hmrc_mtd",
                                                    taxpayer_id: r.id)
  end

  # A scheme that stops at tagging and export gets no block at all.
  test "a scheme with no connector produces no connection block" do
    e = subscribed("81", "DE Only", %w[de_euer])
    get edit_tax_entity_path(e, locale: :en)
    assert_response :success
    assert_select "section[id$=_connection]", count: 0
  end

  # The page must have exactly ONE Save. With two forms, unticking a scheme and
  # then clicking the nearer Save discarded the change and still said "saved".
  test "the tax setup page has a single submit button" do
    e = subscribed("82", "GB One Save", %w[gb_self_employment])
    r = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me")
    e.report_groups.where.not(tax_scheme: nil).each { |g| g.update!(taxpayer: r) }

    get edit_tax_entity_path(e, locale: :en)
    assert_response :success
    assert_select "form#edit_tax_entity input[type=submit]", count: 1
    # …and the filing fields are inside that form, not a second one.
    assert_select "form#edit_tax_entity select[name=?]", "filing[hmrc][taxpayer_id]"
  end

  # A business identifier cannot be known until the authority names it, so it is
  # not offered before connecting. An empty box invites the nearest number to
  # hand — which is how an MTD enrolment id once ended up stored as one.
  test "no business field until the taxpayer is connected" do
    e = subscribed("90", "GB Unconnected", %w[gb_self_employment])
    t = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me")
    e.report_groups.where.not(tax_scheme: nil).each { |g| g.update!(taxpayer: t) }

    get edit_tax_entity_path(e, locale: :en)
    assert_response :success
    assert_select "[name=?]", "filing[hmrc][business_ids][gb_self_employment]", count: 0
  end

  test "once connected the businesses the authority holds are offered" do
    e = subscribed("91", "GB Connected", %w[gb_self_employment])
    t = connected_taxpayer
    e.report_groups.where.not(tax_scheme: nil).each { |g| g.update!(taxpayer: t) }

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Company X" },
      { "businessId" => "XBIS222", "tradingName" => "Second Trade" }
    ]) { get edit_tax_entity_path(e, locale: :en) }

    assert_response :success
    assert_select "select[name=?]", "filing[hmrc][business_ids][gb_self_employment]"
    assert_select "option[value=?]", "XBIS111", text: /Company X/
    assert_select "option[value=?]", "XBIS222"
  end

  # The dropdown is only an affordance. A value the authority never offered did
  # not come from the authority, and filing against it would send this entity's
  # figures as someone else's business — accepted, and wrong.
  test "a business id the authority never offered is refused" do
    e = subscribed("92", "GB Forged", %w[gb_self_employment])
    t = connected_taxpayer

    with_businesses("gb_self_employment" => [ { "businessId" => "XBIS111" } ]) do
      save_filing(e, t, "XPIT00913551259")
    end
    assert_nil e.report_groups.find_by(tax_scheme: "gb_self_employment").business_id
  end

  test "but one it does offer is kept" do
    e = subscribed("93", "GB Real", %w[gb_self_employment])
    t = connected_taxpayer

    with_businesses("gb_self_employment" => [ { "businessId" => "XBIS111" } ]) do
      save_filing(e, t, "XBIS111")
    end
    assert_equal "XBIS111", e.report_groups.find_by(tax_scheme: "gb_self_employment").business_id
  end

  # An unreachable authority must not wipe what is already stored.
  test "an unreachable authority leaves the submitted id alone" do
    e = subscribed("94", "GB Offline", %w[gb_self_employment])
    t = connected_taxpayer

    with_businesses({}) { save_filing(e, t, "XBIS999") }
    assert_equal "XBIS999", e.report_groups.find_by(tax_scheme: "gb_self_employment").business_id
  end

  # HMRC's own schema requires only businessId and typeOfBusiness; tradingName
  # is optional, and SA103F says why: "Business name — unless it's in your own
  # name".
  #
  # Two businesses a person cannot tell apart is a choice by coin toss, and
  # losing it is silent — each update replaces the last one for that business,
  # so the wrong trade's figures are simply kept. We refuse instead.

  def connected_books(code, name)
    e = subscribed(code, name, %w[gb_self_employment])
    t = connected_taxpayer
    e.report_groups.where.not(tax_scheme: nil).each { |g| g.update!(taxpayer: t) }
    [ e, t ]
  end

  # One business is never ambiguous: nothing to confuse it with, so refusing
  # would block a setup that cannot go wrong.
  test "a single nameless business is still offered" do
    e, _t = connected_books("95", "GB Lone")

    with_businesses("gb_self_employment" => [ { "businessId" => "XBIS111" } ]) do
      get edit_tax_entity_path(e, locale: :en)
    end

    assert_response :success
    assert_select "select[name=?]", "filing[hmrc][business_ids][gb_self_employment]"
    assert_select "option[value=?]", "XBIS111"
  end

  test "two businesses with distinct names are offered as usual" do
    e, _t = connected_books("96", "GB Distinct")

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Plastering" },
      { "businessId" => "XBIS222", "tradingName" => "Photography" }
    ]) { get edit_tax_entity_path(e, locale: :en) }

    assert_response :success
    assert_select "select[name=?]", "filing[hmrc][business_ids][gb_self_employment]"
  end

  test "two businesses and one has no name: no field, and a way to fix it" do
    e, _t = connected_books("97", "GB Nameless")

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Plastering" },
      { "businessId" => "XBIS222" }
    ]) { get edit_tax_entity_path(e, locale: :en) }

    assert_response :success
    assert_select "[name=?]", "filing[hmrc][business_ids][gb_self_employment]", count: 0
    assert_select "a[href=?]", "https://www.gov.uk/tell-hmrc-changed-business-details",
                  text: I18n.t("filing.register.business_names_fix")
    # The reason has to be ON the page, not just the absence of a field — being
    # told nothing is how you conclude the app is broken.
    assert_includes response.body,
                    I18n.t("filing.register.business_names_not_unique", authority: "HMRC")
  end

  # The case a presence check would wave through: both named, both the same.
  test "two businesses sharing a name are refused too" do
    e, _t = connected_books("98", "GB Same Name")

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Daniela" },
      { "businessId" => "XBIS222", "tradingName" => " daniela " }
    ]) { get edit_tax_entity_path(e, locale: :en) }

    assert_response :success
    assert_select "[name=?]", "filing[hmrc][business_ids][gb_self_employment]", count: 0
  end

  # Blocking must not destroy a choice made when the list WAS clear: registering
  # a second, nameless trade today cannot lose last week's identifier.
  test "a blocked scheme leaves the stored business id alone" do
    e, t = connected_books("99", "GB Was Clear")
    e.report_groups.find_by(tax_scheme: "gb_self_employment").update!(business_id: "XBIS111")

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Plastering" },
      { "businessId" => "XBIS222" }
    ]) { save_filing(e, t, "XBIS222") }

    assert_equal "XBIS111", e.report_groups.find_by(tax_scheme: "gb_self_employment").business_id
  end

  # ── one business, one set of books ────────────────────────────────────────

  def claimed_elsewhere(taxpayer, business_id)
    other = Entity.create!(code: "60", name: "Other Books", active: true,
                                tax_schemes: [ "gb_self_employment" ])
    other.report_groups.create!(name: "gb-self-employment", tax_scheme: "gb_self_employment",
                                taxpayer: taxpayer, business_id: business_id)
  end

  test "a business already claimed by another of the taxpayer's groups is not offered" do
    e, t = connected_books("61", "GB Second Books")
    claimed_elsewhere(t, "XBIS111")

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Plastering" },
      { "businessId" => "XBIS222", "tradingName" => "Photography" }
    ]) { get edit_tax_entity_path(e, locale: :en) }

    assert_response :success
    assert_select "option[value=?]", "XBIS111", count: 0
    assert_select "option[value=?]", "XBIS222"
  end

  test "and choosing it anyway is refused" do
    e, t = connected_books("62", "GB Forged Claim")
    claimed_elsewhere(t, "XBIS111")

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Plastering" },
      { "businessId" => "XBIS222", "tradingName" => "Photography" }
    ]) { save_filing(e, t, "XBIS111") }

    assert_nil e.report_groups.find_by(tax_scheme: "gb_self_employment").business_id
  end

  # A group's own business is still its own — re-saving must not filter it out.
  test "a group keeps the business it already holds" do
    e, t = connected_books("63", "GB Keeps")
    e.report_groups.find_by(tax_scheme: "gb_self_employment").update!(business_id: "XBIS111")

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Plastering" },
      { "businessId" => "XBIS222", "tradingName" => "Photography" }
    ]) { save_filing(e, t, "XBIS111") }

    assert_equal "XBIS111", e.report_groups.find_by(tax_scheme: "gb_self_employment").business_id
  end

  # Every business spoken for is NOT the same as an unreachable authority: the
  # free-text fallback exists for an authority that did not answer, and must not
  # open here — an unclaimed business does not exist to be typed.
  test "when every business is claimed there is no field and no free text" do
    e, t = connected_books("64", "GB Nothing Left")
    claimed_elsewhere(t, "XBIS111")

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Plastering" }
    ]) { get edit_tax_entity_path(e, locale: :en) }

    assert_response :success
    assert_select "[name=?]", "filing[hmrc][business_ids][gb_self_employment]", count: 0
    assert_includes response.body,
                    I18n.t("filing.register.business_all_claimed", authority: "HMRC")

    with_businesses("gb_self_employment" => [
      { "businessId" => "XBIS111", "tradingName" => "Plastering" }
    ]) { save_filing(e, t, "XBIS111") }

    assert_nil e.report_groups.find_by(tax_scheme: "gb_self_employment").business_id
  end

  # Unticking must actually untick — the failure was silent.
  test "unticking a scheme and saving removes it" do
    e = subscribed("86", "GB Untick", %w[gb_self_employment gb_property])
    patch update_tax_entity_path(e, locale: :en), params: {
      entity: { tax_schemes: [ "" ] }
    }
    assert_equal [], e.reload.tax_schemes
  end

  # Subscribing is only half the job, since the accounts still have to be
  # assigned, so the redirect lands on the new scheme's own page.
  #
  # The scheme list is plain ERB and must actually be in the HTML: drawn by
  # JavaScript into an empty div, the field was invisible without a working
  # script.
  test "the scheme checkboxes are server-rendered, not left to JavaScript" do
    e = Entity.create!(code: "83", name: "GB Server", active: true,
                            tax_schemes: [ "gb_self_employment" ])
    get edit_tax_entity_path(e, locale: :en)
    assert_response :success

    assert_select "fieldset legend", minimum: 1
    assert_select "input[type=checkbox][name=?][value=?]",
                  "entity[tax_schemes][]", "gb_self_employment"
    assert_select "input[type=checkbox][value=?][checked]", "gb_self_employment"
    assert_select "input[type=checkbox][value=?]:not([checked])", "gb_property"
  end

  # Creating or renaming an entity has nothing to do with which returns it
  # files, and two places to tick the same boxes means two to keep in step.
  test "the entity form itself offers no tax schemes" do
    e = Entity.create!(code: "84", name: "GB Plain", active: true)
    get edit_entity_path(e, locale: :en)
    assert_response :success
    assert_select "input[name=?]", "entity[tax_schemes][]", count: 0
  end

  # The link is named after the report group, not a generic word — you are going
  # to THAT scheme's page, so it may as well say which.
  test "the assignment link carries the report group's own name" do
    e = Entity.create!(code: "85", name: "GB Named", active: true,
                            tax_schemes: [ "gb_self_employment" ])
    group = e.report_groups.create!(name: "gb_self_employment", tax_scheme: "gb_self_employment")

    get edit_tax_entity_path(e, locale: :en)
    assert_select "a[href=?]", report_group_path(group, locale: :en),
                  text: group.display_name
  end

  # edit_tax re-renders on a failed save, and the form needs the same data it
  # needed the first time — the one path where the user most needs to see it.
  test "a rejected save re-renders the form with its scheme list intact" do
    e = Entity.create!(code: "86", name: "GB Reject", active: true, tax_schemes: [])
    patch update_tax_entity_path(e, locale: :en), params: {
      entity: { tax_schemes: [ "", "not_a_real_scheme" ] }
    }
    assert_response :unprocessable_entity
    assert_select "fieldset legend", minimum: 1
  end

  # Coming BACK to tax setup, you want a way to the bulk-assignment page. Only
  # for saved schemes: one you have merely ticked has no report group yet.
  test "tax setup links to the report group of each saved scheme" do
    e = Entity.create!(code: "81", name: "GB Links", active: true,
                            tax_schemes: [ "gb_self_employment" ])
    group = e.report_groups.create!(name: "gb_self_employment", tax_scheme: "gb_self_employment")

    get edit_tax_entity_path(e, locale: :en)
    assert_response :success
    assert_select "a[href=?]", report_group_path(group, locale: :en)
  end

  test "an entity with no schemes offers no assignment links" do
    e = Entity.create!(code: "82", name: "GB Bare", active: true, tax_schemes: [])
    get edit_tax_entity_path(e, locale: :en)
    assert_response :success
    assert_select "a[href*=?]", "report_groups", count: 0
  end

  test "subscribing to a scheme lands on that scheme's report group" do
    e = Entity.create!(code: "76", name: "GB Three", active: true, tax_schemes: ["gb_self_employment"])
    patch update_tax_entity_path(e, locale: :en), params: {
      entity: {
                    tax_schemes: ["", "gb_self_employment", "gb_property"] }
    }
    group = e.report_groups.find_by(tax_scheme: "gb_property")
    assert group, "the scheme's report group should exist by the time we redirect"
    assert_redirected_to report_group_path(group, locale: :en)
  end

  # Ticking a scheme must NOT load its catalogue from the YAML files. As a
  # safety net for a fresh install it was worse than the gap it filled: the
  # loader DELETES categories a file no longer declares, so a user's save could
  # strand another bookkeeper's accounts, at an arbitrary moment, with nothing
  # printed anywhere.
  #
  # The catalogues load with the code — .kamal/hooks/pre-deploy, after
  # db:migrate — and by hand while developing.
  test "ticking a scheme does NOT load the catalogue: that is a deploy step" do
    e = Entity.create!(code: "77", name: "GB Cat", active: true, tax_schemes: ["gb_self_employment"])
    TaxCategory.where(country_code: "gb", scheme: "gb_property").delete_all

    patch update_tax_entity_path(e, locale: :en), params: {
      entity: { tax_schemes: ["", "gb_self_employment", "gb_property"] }
    }

    assert_redirected_to report_group_path(e.report_groups.find_by(tax_scheme: "gb_property"), locale: :en)
    assert_equal 0, TaxCategory.where(country_code: "gb", scheme: "gb_property").count,
           "a user's save must not write reference data"
  end

  # The corollary: saving the form can no longer delete anyone's categories,
  # so it can never strand an account either.
  test "ticking a scheme cannot enqueue a removal notification" do
    e = Entity.create!(code: "79", name: "No Load", active: true, tax_schemes: [])

    assert_no_enqueued_jobs(only: TaxCategoryRemovalNotificationJob) do
      patch update_tax_entity_path(e, locale: :en), params: {
        entity: { tax_schemes: ["", "gb_self_employment"] }
      }
    end
  end

  test "ticking a scheme with no accounts to assign uses the no-accounts notice" do
    e = Entity.create!(code: "78", name: "GB Guide", active: true, tax_schemes: [])
    patch update_tax_entity_path(e, locale: :en), params: {
      entity: { tax_schemes: ["", "gb_self_employment"] }
    }
    assert_redirected_to report_group_path(e.report_groups.find_by(tax_scheme: "gb_self_employment"), locale: :en)
    # No income/expense accounts exist → the "no accounts yet" notice, not the
    # "category suggestions are shown" one.
    assert_equal I18n.t("entities.edit_tax.updated_no_accounts"), flash[:notice]
    assert_not_equal I18n.t("entities.edit_tax.updated"), flash[:notice]
  end

  test "unticking a scheme uses the unsubscribed notice" do
    e = Entity.create!(code: "79", name: "GB Unsub", active: true, tax_schemes: ["gb_self_employment", "gb_property"])
    patch update_tax_entity_path(e, locale: :en), params: {
      entity: { tax_schemes: ["", "gb_self_employment"] }
    }
    assert_redirected_to dashboard_path(locale: :en)
    # The scheme's own name, from its tax category file, not a locale key. A tax
    # form's name does not translate: "UK Property (SA105)" reads the same in
    # all four languages.
    scheme = TaxSchemeConfig.scheme_label("gb_property")
    assert_equal "UK Property (SA105)", scheme, "must be the form's own name"
    assert_equal I18n.t("entities.edit_tax.unsubscribed", schemes: scheme), flash[:notice]
  end

  # The picker for a scheme that has only just been ticked. filing_authorities
  # is built from SAVED schemes and must stay that way, or unticking one would
  # leave its fieldset behind — so the page fetches the block for a pending
  # scheme instead, and keeps its one Save.

  test "the picker for a pending scheme is fetched, and posts into the same form" do
    e = subscribed("83", "GB Pending", [])

    get filing_fields_entity_path(e, locale: :en, scheme: "gb_property")
    assert_response :success
    assert_select "select[name=?]", "filing[hmrc][taxpayer_id]"
    # No groups yet, so nothing is asked of the authority.
    assert_select "input[name^=?]", "filing[hmrc][business_ids]", count: 0
  end

  test "nothing is offered for a scheme that cannot be filed" do
    e = subscribed("84", "DE Pending", [])

    get filing_fields_entity_path(e, locale: :en, scheme: "de_euer")
    assert_response :no_content
  end

  # One taxpayer per authority — a second picker would be a second answer to a
  # question that has one.
  test "nor for an authority already on the page" do
    e = subscribed("85", "GB Already", %w[gb_self_employment])

    get filing_fields_entity_path(e, locale: :en, scheme: "gb_property")
    assert_response :no_content
  end

  test "an unknown scheme is refused" do
    e = subscribed("86", "GB Unknown", [])

    get filing_fields_entity_path(e, locale: :en, scheme: "not_a_scheme")
    assert_response :no_content
  end

  # Only these carry data-authority, so the question is never asked for a
  # scheme that stops at tagging and export.
  test "submittable schemes are marked for the question, others are not" do
    e = subscribed("87", "GB Marks", [])
    get edit_tax_entity_path(e, locale: :en)

    assert_select "input#entity_tax_scheme_gb_property[data-authority=?]", "hmrc"
    assert_select "input#entity_tax_scheme_euer[data-authority]", count: 0
  end

  test "read-only admins cannot reach the picker" do
    e = subscribed("88", "GB Locked", [])
    sign_out
    sign_in_as(admins(:read_only))

    get filing_fields_entity_path(e, locale: :en, scheme: "gb_property")
    assert_response :redirect
  end

  test "non-sudo cannot create" do
    sign_out
    sign_in_as(admins(:two))
    post entities_path(locale: :en), params: {
      entity: { code: "74", name: "Z", active: true }
    }
    assert_response :redirect
  end
end
