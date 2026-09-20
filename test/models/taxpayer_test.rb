# frozen_string_literal: true
require "test_helper"

# One taxpayer as ONE AUTHORITY knows them. Not one human — see the model.
class TaxpayerTest < ActiveSupport::TestCase
  setup do
    @admin = admins(:sudo)
  end

  def taxpayer(attrs = {})
    Taxpayer.create!({ admin: @admin, authority: "hmrc" }.merge(attrs))
  end

  test "an authority is required" do
    refute Taxpayer.new(admin: @admin).valid?
  end

  # The case the old shape got wrong: a bookkeeper holds one per client, all at
  # the same authority, so nothing may enforce uniqueness there.
  test "an admin may hold several taxpayers at the same authority" do
    taxpayer(label: "Client A")
    assert taxpayer(label: "Client B").persisted?
    assert_equal 2, Taxpayer.for_authority("hmrc").where(admin: @admin).count
  end

  test "and taxpayers at different authorities — one human, two of these" do
    taxpayer
    assert taxpayer(authority: "elster").persisted?
    assert_equal 1, Taxpayer.for_authority("elster").count
  end

  # ── permission ────────────────────────────────────────────────────────────

  test "tokens are encrypted at rest but read back plainly" do
    r = taxpayer(access_token: "secret-access", refresh_token: "secret-refresh")

    assert_equal "secret-access", r.reload.access_token
    raw = Taxpayer.connection.select_value(
      "SELECT access_token FROM taxpayers WHERE id = #{r.id}"
    )
    refute_equal "secret-access", raw, "the column must not hold the token in clear"
  end

  test "connected? is about holding a token, expired? about its age" do
    refute taxpayer.connected?

    r = taxpayer(label: "B", access_token: "x", token_expires_at: 1.hour.ago)
    assert r.connected?
    assert r.expired?
  end

  # Disconnecting ends the permission. The number is the person's and they will
  # need it again to reconnect.
  test "clear! drops the permission and keeps the number" do
    r = taxpayer(access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    r.set_identifier(:nino, "AB123456C")
    r.save!

    r.clear!
    r.reload

    assert_nil r.access_token
    assert_nil r.refresh_token
    assert_nil r.token_expires_at
    assert_equal "AB123456C", r.identifier(:nino)
  end

  # ── identifiers ───────────────────────────────────────────────────────────

  # Deliberately readable: these identify, they do not grant. See the migration.
  test "identifiers are stored in the clear so they stay queryable" do
    r = taxpayer
    r.set_identifier(:nino, "AB123456C")
    r.save!

    raw = Taxpayer.connection.select_value(
      "SELECT identifiers FROM taxpayers WHERE id = #{r.id}"
    )
    assert_includes raw, "AB123456C"
  end

  test "one identifier does not disturb another" do
    r = taxpayer
    r.set_identifier(:nino, "AB123456C")
    r.set_identifier(:utr,  "1234567890")
    r.save!

    r.reload
    assert_equal "AB123456C",  r.identifier(:nino)
    assert_equal "1234567890", r.identifier("utr")
    assert_nil   r.identifier(:steuernummer)
  end

  test "a blank identifier is removed rather than stored empty" do
    r = taxpayer
    r.set_identifier(:nino, "AB123456C")
    r.save!
    r.set_identifier(:nino, "")
    r.save!

    assert_nil r.reload.identifier(:nino)
  end

  # Normalisation belongs to the connector — only it knows HMRC will not match
  # "ab 12 34 56 c". The model does not quietly fix it either: it refuses, so
  # nothing can store a number the authority will reject.
  test "the model does not normalise — it refuses" do
    r = taxpayer
    r.set_identifier(:nino, "ab 12 34 56 c")

    refute r.save
    assert_equal "ab 12 34 56 c", r.identifier(:nino), "and it does not rewrite it"
  end

  # ── the shape of a number ─────────────────────────────────────────────────

  test "a NINO must be two letters, six digits and a final A-D" do
    r = taxpayer
    %w[AB123456C AB123456A].each do |good|
      r.set_identifier(:nino, good)
      assert r.valid?, "#{good} should be accepted"
    end

    %w[AB12345C AB1234567C AB123456E A1123456C].each do |bad|
      r.set_identifier(:nino, bad)
      refute r.valid?, "#{bad} should be rejected"
    end
  end

  # A bookkeeper may have the client before the paperwork. Connect is where it
  # genuinely cannot go on without one.
  test "no number at all is fine" do
    assert taxpayer.persisted?
  end

  # ── one number, one row, within reach ─────────────────────────────────────

  test "an admin cannot hold the same number twice at one authority" do
    a = taxpayer(label: "Client A")
    a.set_identifier(:nino, "AB123456C")
    a.save!

    b = Taxpayer.new(admin: @admin, authority: "hmrc", label: "Same person again")
    b.set_identifier(:nino, "AB123456C")
    refute b.valid?
  end

  test "but the same number at a different authority is a different person" do
    a = taxpayer
    a.set_identifier(:nino, "AB123456C")
    a.save!

    b = Taxpayer.new(admin: @admin, authority: "elster")
    b.set_identifier(:nino, "AB123456C")
    assert b.valid?, "elster declares no nino, so nothing collides"
  end

  test "updating a taxpayer does not collide with itself" do
    r = taxpayer
    r.set_identifier(:nino, "AB123456C")
    r.save!

    r.label = "Renamed"
    assert r.valid?
  end

  # The record stays with its creator; the right to FILE follows the entity. A
  # bookkeeper and their assistant share entities, so they share one grant
  # instead of asking the client to authorise the same app twice.

  def filing_group(entity, taxpayer)
    ReportGroup.create!(name: "Filed #{entity.code}", entity: entity, taxpayer: taxpayer)
  end

  test "a taxpayer filing for an entity is usable by everyone who can write to it" do
    r = Taxpayer.create!(admin: admins(:two), authority: "hmrc", label: "Client")
    filing_group(entities(:family_biz), r)

    assert_includes admins(:two).usable_taxpayers, r,   "its creator"
    assert_includes admins(:mixed).usable_taxpayers, r, "full access to 10, so files it too"
  end

  test "and by nobody else" do
    r = Taxpayer.create!(admin: admins(:two), authority: "hmrc", label: "Client")
    filing_group(entities(:family_biz), r)

    refute_includes admins(:one).usable_taxpayers, r, "no access to 10 at all"
  end

  # Writable, not accessible: reading someone's books is not filing them.
  test "read-only access to the entity does not reach its taxpayer" do
    r = Taxpayer.create!(admin: admins(:one), authority: "hmrc", label: "Client")
    filing_group(entities(:personal), r)

    assert_includes admins(:one).usable_taxpayers, r,   "full access to 01"
    refute_includes admins(:mixed).usable_taxpayers, r, "read_only on 01"
  end

  test "a taxpayer attached to nothing is its creator's alone" do
    r = Taxpayer.create!(admin: admins(:two), authority: "hmrc", label: "Fresh")

    assert_includes admins(:two).usable_taxpayers, r
    refute_includes admins(:mixed).usable_taxpayers, r
  end

  # ── deleting ──────────────────────────────────────────────────────────────

  test "a taxpayer still filing for a group will not delete" do
    r = taxpayer(label: "Client")
    filing_group(entities(:family_biz), r)

    refute r.destroy
    assert Taxpayer.exists?(r.id)
    assert_equal [ "10" ], r.entity_codes_in_use
  end

  test "and deletes once nothing names it" do
    r = taxpayer(label: "Client")
    filing_group(entities(:family_biz), r).update!(taxpayer: nil)

    assert r.destroy
  end

  # Deleting an admin must not take a taxpayer someone else is still filing
  # with — that would leave their books unfilable with nothing to say why.
  test "deleting the creator releases what is in use and destroys what is not" do
    creator = admins(:two)
    kept = Taxpayer.create!(admin: creator, authority: "hmrc", label: "Shared")
    gone = Taxpayer.create!(admin: creator, authority: "hmrc", label: "Unused")
    filing_group(entities(:family_biz), kept)

    creator.destroy

    assert_nil kept.reload.admin_id, "released, and still usable through its entity"
    refute Taxpayer.exists?(gone.id), "nobody was using it"
    assert_includes admins(:mixed).usable_taxpayers, kept
  end

  # ── the link to a group ───────────────────────────────────────────────────

  test "display_name falls back to the authority, never to the number" do
    assert_equal "HMRC", taxpayer.display_name
    assert_equal "Laura — HMRC", taxpayer(label: "Laura — HMRC").display_name
  end

  test "a group is filable only with a taxpayer, a business id and permission" do
    entity = entities(:family_biz)
    group  = entity.report_groups.create!(name: "se", tax_scheme: "gb_self_employment")
    refute group.filable?, "no taxpayer, no business id"

    group.update!(business_id: "XBIS1", taxpayer: taxpayer)
    refute group.filable?, "a taxpayer without a token is not permission"

    group.taxpayer.update!(access_token: "tok")
    assert group.reload.filable?
  end

  # An entity files to one authority as ONE taxpayer. Unreachable through the
  # page — one picker per authority writes to every group behind it — so this
  # guards the console.
  test "two groups at one authority cannot name two taxpayers" do
    entity = entities(:family_biz)
    mine   = taxpayer(label: "Me")
    theirs = taxpayer(label: "Someone else")

    entity.report_groups.create!(name: "se", tax_scheme: "gb_self_employment", taxpayer: mine)
    clash = entity.report_groups.build(name: "prop", tax_scheme: "gb_property", taxpayer: theirs)

    refute clash.valid?
    assert clash.errors[:taxpayer_id].any?
  end

  test "but the same taxpayer across both is fine" do
    entity = entities(:family_biz)
    mine   = taxpayer(label: "Me")

    entity.report_groups.create!(name: "se", tax_scheme: "gb_self_employment", taxpayer: mine)
    assert entity.report_groups.build(name: "prop", tax_scheme: "gb_property",
                                      taxpayer: mine).valid?
  end

  # Different authorities are a different question: one person has a NINO and a
  # Steuernummer, so two taxpayers, and both may file from one entity.
  test "an authority with no connector does not clash" do
    entity = entities(:family_biz)
    mine   = taxpayer(label: "Me")
    other  = taxpayer(authority: "elster", label: "Me at ELSTER")

    entity.report_groups.create!(name: "se", tax_scheme: "gb_self_employment", taxpayer: mine)
    assert entity.report_groups.build(name: "de_euer", tax_scheme: "de_euer",
                                      taxpayer: other).valid?
  end

  # Losing the taxpayer must not take the reports with it — and now it cannot
  # happen by accident at all: the group has to be detached deliberately first.
  test "a group survives losing its taxpayer, and blocks the deletion until it does" do
    entity = entities(:family_biz)
    r      = taxpayer
    group  = entity.report_groups.create!(name: "se", tax_scheme: "gb_self_employment",
                                          taxpayer: r)

    refute r.destroy, "still filing these books"

    group.update!(taxpayer: nil)
    assert r.destroy
    assert group.reload.persisted?
  end
end
