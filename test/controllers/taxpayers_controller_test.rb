# frozen_string_literal: true
require "test_helper"

# An admin's own taxpayers, scoped to current_admin throughout. This is the list
# you choose FROM when saying whose figures a tax report group holds — and a
# taxpayer attached to an entity could not be shared between one taxpayer's
# several sets of books.
class TaxpayersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(admins(:sudo))
  end

  test "the index leaves out taxpayers filing for entities this admin cannot reach" do
    mine   = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Mine")
    theirs = admins(:two).taxpayers.create!(authority: "hmrc", label: "Theirs")

    get taxpayers_path(locale: :en)
    assert_response :success
    assert_includes @response.body, mine.label
    refute_includes @response.body, theirs.label
  end

  test "creating one normalises the identifier through its connector" do
    assert_difference("Taxpayer.count", 1) do
      post taxpayers_path(locale: :en), params: {
        taxpayer: { authority: "hmrc", label: "  Laura  ",
                            identifiers: { "nino" => "ab 12 34 56 c" } }
      }
    end

    r = admins(:sudo).taxpayers.last
    assert_equal "Laura",     r.label
    assert_equal "AB123456C", r.identifier(:nino),
                 "HMRC will not match a NINO with spaces or lower case in it"
  end

  test "the form offers the identifiers the connector declares" do
    get new_taxpayer_path(locale: :en, authority: "hmrc")
    assert_response :success
    assert_select "input[name=?]", "taxpayer[identifiers][nino]"
  end

  test "an authority with no connector is not offered" do
    get new_taxpayer_path(locale: :en)
    assert_response :success
    assert_select "select[name=?] option[value=?]", "taxpayer[authority]", "elster", count: 0
  end

  test "editing updates the number without touching the permission" do
    r = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Laura",
                                            access_token: "tok")
    patch taxpayer_path(r, locale: :en), params: {
      taxpayer: { authority: "hmrc", label: "Laura",
                          identifiers: { "nino" => "CD654321B" } }
    }

    r.reload
    assert_equal "CD654321B", r.identifier(:nino)
    assert_equal "tok", r.access_token
  end

  test "another admin's taxpayer cannot be reached" do
    theirs = admins(:two).taxpayers.create!(authority: "hmrc", label: "Theirs")
    get edit_taxpayer_path(theirs, locale: :en)
    assert_redirected_to taxpayers_path(locale: :en)
  end

  # The books and their reports are not the taxpayer's to take with it, and they
  # cannot lose it silently either: the deletion is refused, and the alert names
  # the entity holding it.
  test "deleting one is refused while a tax report group still names it" do
    r      = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Laura")
    entity = entities(:family_biz)
    group  = entity.report_groups.create!(name: "se", tax_scheme: "gb_self_employment",
                                          taxpayer: r)

    delete taxpayer_path(r, locale: :en)
    assert_redirected_to taxpayers_path(locale: :en)
    assert_includes flash[:alert], entity.code
    assert Taxpayer.exists?(r.id)
    assert_equal r, group.reload.taxpayer

    group.update!(taxpayer: nil)
    delete taxpayer_path(r, locale: :en)
    refute Taxpayer.exists?(r.id)
    assert group.reload.persisted?
  end

  # ── the index: whose it is, its number, its books (Q6/Q7) ────────────────

  test "the index names the creator, masks the number, and lists the report groups" do
    tp     = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Laura",
                                             identifiers: { "nino" => "AB123456C" })
    entity = entities(:family_biz)
    group  = entity.report_groups.create!(name: "prop", tax_scheme: "gb_property", taxpayer: tp)

    get taxpayers_path(locale: :en)
    assert_response :success
    assert_includes @response.body, admins(:sudo).username
    assert_includes @response.body, "••••••••C"
    refute_includes @response.body, "AB123456C",
                    "a full NINO must never sit on a list of clients"
    assert_includes @response.body, "#{entity.code} · #{group.display_name}"
  end

  # ── Q4: back to where you came from, if that was a tax setup page ─────────

  test "the back link returns to the tax setup page it was opened from" do
    path = edit_tax_entity_path(entities(:family_biz), locale: :en)

    get taxpayers_path(locale: :en, return_to: path)
    assert_response :success
    assert_select "a.button[href='#{path}']", text: I18n.t("crud.back")
  end

  test "a return_to that is not a tax setup or profile page falls back to the dashboard" do
    dash = dashboard_path(locale: :en)
    [ "https://evil.example/steal", "/en/entities", "//evil.example" ].each do |bad|
      get taxpayers_path(locale: :en, return_to: bad)
      assert_select "a.button[href='#{dash}']", { text: I18n.t("crud.back") },
                    "return_to=#{bad.inspect} should be ignored"
    end
  end

  test "the return_to is carried through Add and Edit so the whole detour comes back" do
    tp   = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Laura")
    path = edit_tax_entity_path(entities(:family_biz), locale: :en)

    get taxpayers_path(locale: :en, return_to: path)
    assert_select "a[href='#{new_taxpayer_path(locale: :en, return_to: path)}']"
    assert_select "a[href='#{edit_taxpayer_path(tp, locale: :en, return_to: path)}']"

    patch taxpayer_path(tp, locale: :en), params: {
      taxpayer: { authority: "hmrc", label: "Laura B" }, return_to: path
    }
    assert_redirected_to taxpayers_path(locale: :en, return_to: path)
  end

  # ── added from the tax setup page, without leaving it ─────────────────────

  # The modal the tax setup page opens the moment you say you file from the app.
  # Always both ways out, so you are never made to retype a client you already
  # have, and never stuck when you have none.
  test "the chooser offers the taxpayers you may use, and a way to add one" do
    mine = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Mine")

    get choose_taxpayers_path(locale: :en, authority: "hmrc")
    assert_response :success

    assert_select "select#choose_taxpayer_id option[value=?]", mine.id.to_s
    assert_select "[data-taxpayer-use=?]", "hmrc"
    assert_select "[data-taxpayer-new=?]", "hmrc"
  end

  test "with nobody on file it offers only adding" do
    get choose_taxpayers_path(locale: :en, authority: "hmrc")
    assert_response :success

    assert_select "select#choose_taxpayer_id", count: 0
    assert_select "[data-taxpayer-use]", count: 0
    assert_select "[data-taxpayer-new=?]", "hmrc"
  end

  test "the chooser needs an authority" do
    get choose_taxpayers_path(locale: :en)
    assert_response :no_content
  end

  test "the modal form is bare, and its authority is shown rather than chosen" do
    get new_taxpayer_path(locale: :en, authority: "hmrc", modal: 1)
    assert_response :success

    assert_select "select[name=?]", "taxpayer[authority]", { count: 0 },
                  "the block you clicked already decided it"
    assert_select "input[name=?][type=hidden]", "taxpayer[authority]"
    assert_select "input[name=?]", "taxpayer[identifiers][nino]"
    assert_select "h1", { count: 0 }, "no page furniture inside a dialog"
  end

  test "and the plain page still offers the choice" do
    get new_taxpayer_path(locale: :en, authority: "hmrc")
    assert_response :success
    assert_select "select[name=?]", "taxpayer[authority]"
  end

  # The picker needs the new record back to select it. Only the TAXPAYER is
  # saved — the tax setup still waits for that page's one Save.
  test "creating one answers json for the modal" do
    post taxpayers_path(locale: :en, format: :json), params: {
      taxpayer: { authority: "hmrc", label: "Laura",
                      identifiers: { "nino" => "ab 12 34 56 c" } }
    }
    assert_response :success

    body = JSON.parse(@response.body)
    assert_equal "Laura", body["display_name"]
    assert_equal admins(:sudo).taxpayers.last.id, body["id"]
  end

  test "and hands back the errors when it will not save" do
    post taxpayers_path(locale: :en, format: :json), params: {
      taxpayer: { authority: "hmrc", label: "Laura",
                      identifiers: { "nino" => "nonsense" } }
    }
    assert_response :unprocessable_entity
    assert JSON.parse(@response.body)["errors"].any?
  end

  # A bookkeeper and their assistant share entities, so they share the taxpayer:
  # one HMRC grant, not one each. Without it the assistant could submit — the
  # client reads the taxpayer off the group — but could not pick it, and could
  # not re-authorise when the token expired.

  test "a taxpayer filing for a shared entity appears in the other admin's list" do
    theirs = admins(:two).taxpayers.create!(authority: "hmrc", label: "Their client")
    entities(:family_biz).report_groups.create!(name: "se", tax_scheme: "gb_self_employment",
                                                   taxpayer: theirs)

    sign_in_as(admins(:mixed)) # full access to 10, read_only on 01
    get taxpayers_path(locale: :en)

    assert_response :success
    assert_includes @response.body, theirs.label
  end

  test "but it is not theirs to edit or delete" do
    theirs = admins(:two).taxpayers.create!(authority: "hmrc", label: "Their client")
    entities(:family_biz).report_groups.create!(name: "se", tax_scheme: "gb_self_employment",
                                                   taxpayer: theirs)

    sign_in_as(admins(:mixed))

    get edit_taxpayer_path(theirs, locale: :en)
    assert_redirected_to taxpayers_path(locale: :en)

    delete taxpayer_path(theirs, locale: :en)
    assert Taxpayer.exists?(theirs.id)
  end

  test "read-only access to the entity does not share its taxpayer" do
    theirs = admins(:one).taxpayers.create!(authority: "hmrc", label: "Their client")
    entities(:personal).report_groups.create!(name: "se", tax_scheme: "gb_self_employment",
                                                  taxpayer: theirs)

    sign_in_as(admins(:mixed)) # read_only on 01
    get taxpayers_path(locale: :en)

    assert_response :success
    refute_includes @response.body, theirs.label
  end
end
