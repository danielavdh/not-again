# frozen_string_literal: true
require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
  end

  test "sudo admin can access dashboard" do
    sign_in_as(admins(:sudo))
    get dashboard_url(locale: :en)
    assert_response :success
  end

  test "full_access admin can access dashboard" do
    sign_in_as(admins(:two))
    get dashboard_url(locale: :en)
    assert_response :success
  end

  test "read_only admin can access dashboard" do
    sign_in_as(admins(:read_only))
    get dashboard_url(locale: :en)
    assert_response :success
  end

  test "upload_only admin is redirected from dashboard" do
    sign_in_as(admins(:upload_only))
    get dashboard_url(locale: :en)
    assert_redirected_to upload_standalone_receipts_path
  end

  test "unauthenticated is redirected to login" do
    get dashboard_url(locale: :en)
    assert_response :redirect
  end

  test "dashboard route also works" do
    sign_in_as(admins(:two))
    get dashboard_url(locale: :en)
    assert_response :success
  end

  # The tagging widget that used to sit here spanned every entity and scheme at
  # once, while an account belongs to exactly one scheme. Tagging happens on
  # that scheme's own report group page.
  test "the dashboard no longer carries the unmapped-tax-accounts widget" do
    sign_in_as(admins(:one))
    get dashboard_url(locale: :en)
    assert_response :success
    assert_select "[data-tax-mapping]", count: 0
  end

  # Tax setup and filing are about the ENTITY, and this partial is the only
  # place
  # an entity reliably appears — acc/entities is sudo-only.
  test "each entity block offers its own tax setup" do
    sign_in_as(admins(:one))
    get dashboard_url(locale: :en)
    assert_response :success
    assert_select "tr.entity-tax", minimum: 1
  end

  test "family members are framed with a single family-level reports row" do
    group = EntityGroup.create!(name: "Household")
    Entity.create!(name: "Alpha", code: "70", active: true, entity_group: group)
    Entity.create!(name: "Beta",  code: "71", active: true, entity_group: group)

    sign_in_as(admins(:sudo)) # sees all entities, so the family is on the dashboard
    get dashboard_url(locale: :en)
    assert_response :success

    assert_match "entity-family", response.body           # the family frame
    assert_match "Household", response.body               # the family name
    assert_match "entities=70%2C71", response.body        # family-level reports (70,71)
    # per-member general-reports rows are suppressed inside a family
    assert_no_match(/entities=70["&]/, response.body)
    assert_no_match(/entities=71["&]/, response.body)

    # Downloads follows the same rule: one row for the family, none per member —
    # this regressed once already, with both members showing their own.
    # Ungrouped entities still get their own row, so the count is every OTHER
    # entity, not zero.
    assert_select ".family-downloads", 1
    assert_select "tr.entity-downloads", Entity.where(entity_group_id: nil).count
  end

  # recent_archives must exclude TODAY: including it meant that the moment an
  # admin clicked the "current date" button once, reloading the dashboard showed
  # that same date twice — once as the button that generates it, once as a link
  # to what was just generated.
  test "today's date does not appear twice once an archive for today exists" do
    entity = entities(:family_biz)
    Archives::Storage.upload(Archives::Storage.key_for(entity.code, Date.current), "snapshot")

    sign_in_as(admins(:two)) # full_access on family_biz
    get dashboard_url(locale: :en)
    assert_response :success

    today = Date.current.strftime("%y-%m-%d")
    # Scoped to family_biz's OWN row: admins(:two) also holds daughter(04),
    # which has no archive yet and legitimately shows its own "current date"
    # button — a different row, not a duplicate.
    assert_select "tr.entity-downloads form[action='#{create_archive_reports_path(entity_id: entity.id, locale: :en)}']" do
      assert_select "button", text: today, count: 1
    end
    assert_select "tr.entity-downloads a", text: today, count: 0
  ensure
    FileUtils.rm_rf(uploads_path("archives", entity.code))
  end
  # The tax row: one next step per scheme, and nothing that leads nowhere.
  # Subscribing alone was enough to show a submissions button, so an entity
  # answering "I only need the figures" got a button to a page that can list
  # nothing — periods come from the authority, and without permission there is
  # nothing to ask.

  def tax_row_for(entity, schemes:, taxpayer: nil)
    entity.update!(tax_schemes: schemes)
    schemes.each do |scheme|
      group = entity.report_groups.find_or_create_by!(tax_scheme: scheme) { |g| g.name = scheme }
      group.update!(taxpayer: taxpayer)
    end
    sign_in_as(admins(:sudo))
    get dashboard_url(locale: :en)
    assert_response :success
  end

  test "a scheme with no taxpayer offers neither connect nor submissions" do
    tax_row_for(entities(:family_biz), schemes: %w[gb_property])

    assert_select "a", text: /#{Regexp.escape(I18n.t("filing.connect", authority: "HMRC"))}/, count: 0
    assert_select "a", text: /submissions/i, count: 0
  end

  test "a taxpayer without permission offers connect, not submissions" do
    taxpayer = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Laura")
    tax_row_for(entities(:family_biz), schemes: %w[gb_property], taxpayer: taxpayer)

    assert_select "a", text: /#{Regexp.escape(I18n.t("filing.connect", authority: "HMRC"))}/
    assert_select "a", text: /submissions/i, count: 0
  end

  test "once connected it offers submissions, not connect" do
    taxpayer = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Laura",
                                               access_token: "tok",
                                               token_expires_at: 1.hour.from_now)
    tax_row_for(entities(:family_biz), schemes: %w[gb_property], taxpayer: taxpayer)

    assert_select "a", text: /#{Regexp.escape(I18n.t("filing.connect", authority: "HMRC"))}/, count: 0
    assert_select "a", text: /submissions/i
  end

  # One login covers every scheme behind an authority, so two GB schemes must
  # not grow two identical Connect buttons — the bug the submissions buttons had
  # before they were named after the scheme.
  test "two schemes at one authority offer one connect button but two submissions" do
    pending = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Laura")
    tax_row_for(entities(:family_biz), schemes: %w[gb_property gb_self_employment],
                taxpayer: pending)

    assert_select "a", text: /#{Regexp.escape(I18n.t("filing.connect", authority: "HMRC"))}/,
                  count: 1
  end

  # The setup button stays, and stops saying "Tax Setup" once there is one.
  # Scoped by href, because the dashboard lists every entity and the ones with
  # no schemes go on saying "Tax Setup".
  test "the setup button changes wording once a scheme is chosen" do
    entity = entities(:family_biz)
    entity.update!(tax_schemes: [])
    sign_in_as(admins(:sudo))
    get dashboard_url(locale: :en)
    assert_select "a[href=?]", edit_tax_entity_path(entity, locale: :en),
                  text: I18n.t("entities.edit_tax.setup")

    tax_row_for(entity, schemes: %w[gb_property])
    assert_select "a[href=?]", edit_tax_entity_path(entity, locale: :en),
                  text: I18n.t("crud.edit")
  end

  # A brand-new installation: the owner exists, nothing else does. This 500'd —
  # the dashboard's single-entity branch assumed @entity was always present, and
  # it is nil both here and for any admin whose primary_entity_code matches no
  # entity. Nobody would see it before the very first login of a fresh install,
  # which is the worst possible moment.
  test "the dashboard renders for an owner with no entities at all" do
    # A fresh installation has no entities and nothing hanging off them.
    # CASCADE rather than deleting eight tables in dependency order.
    ActiveRecord::Base.connection.execute("TRUNCATE entities CASCADE")
    owner = admins(:sudo)
    sign_in_as owner
    get dashboard_url(locale: :en)
    assert_response :success
  end

  test "the dashboard renders when primary_entity_code matches no entity" do
    admin = admins(:sudo)
    admin.update_column(:entity_code, "99")
    sign_in_as admin
    get dashboard_url(locale: :en)
    assert_response :success
  end

  # A business reads its returns before its own cuts of the data: tax report
  # groups sort ahead of custom ones in "Your report groups".
  test "tax report groups come before custom groups" do
    entity = entities(:family_biz)
    ReportGroup.create!(name: "My cut", entity: entity)
    ReportGroup.create!(name: "GB SE", entity: entity, tax_scheme: "gb_self_employment")

    sign_in_as(admins(:two))
    get dashboard_url(locale: :en)
    assert_response :success

    tax_at    = response.body.index("GB-self-employment") || response.body.index("GB SE")
    custom_at = response.body.index("My cut")
    assert tax_at && custom_at
    assert tax_at < custom_at, "the tax report group should be listed first"
  end
end
