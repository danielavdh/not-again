# frozen_string_literal: true

require "test_helper"

class AdminMailerTest < ActionMailer::TestCase
  setup do
    @admin  = admins(:sudo)
    @entity = entities(:family_biz)
  end

  # ==================== tax_export_ready ====================

  test "tax_export_ready subject includes entity name and dates" do
    mail = AdminMailer.with(
      admin: @admin,
      entity: @entity,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 12, 31),
      attachments: { "index.csv" => "Date,Account\n" },
      locale: "en"
    ).tax_export_ready

    assert_includes mail.subject, @entity.name
    assert_includes mail.subject, "2026-01-01"
    assert_includes mail.subject, "2026-12-31"
  end

  test "tax_export_ready attaches CSV files" do
    mail = AdminMailer.with(
      admin: @admin,
      entity: @entity,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 12, 31),
      attachments: {
        "index.csv" => "Date,Account\n",
        "tax-categories.csv" => "Section,Key\n"
      },
      locale: "en"
    ).tax_export_ready

    assert_equal 2, mail.attachments.count
    assert mail.attachments["index.csv"]
    assert mail.attachments["tax-categories.csv"]
  end

  test "tax_export_ready does not attach a zip file" do
    mail = AdminMailer.with(
      admin: @admin,
      entity: @entity,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 12, 31),
      attachments: { "index.csv" => "Date,Account\n" },
      locale: "en"
    ).tax_export_ready

    assert mail.attachments.none? { |a| a.filename.end_with?(".zip") }
  end

  test "tax_export_ready is sent to admin email" do
    mail = AdminMailer.with(
      admin: @admin,
      entity: @entity,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 12, 31),
      attachments: { "index.csv" => "Date,Account\n" },
      locale: "en"
    ).tax_export_ready

    assert_equal [@admin.email_address], mail.to
  end

  # ==================== tax_export_empty ====================

  test "tax_export_empty is sent to admin email" do
    mail = AdminMailer.with(
      admin: @admin,
      entity: @entity,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 12, 31),
      locale: "en"
    ).tax_export_empty

    assert_equal [@admin.email_address], mail.to
  end

  # ==================== filing_submitted ====================

  test "filing_submitted is sent to admin email" do
    mail = AdminMailer.with(
      admin:    @admin,
      entity:   @entity,
      scheme:   "gb_self_employment",
      start_d:  Date.new(2026, 1, 1),
      end_d:    Date.new(2026, 3, 31),
      view_url: "https://accounts.example.com/entities/1/hmrc_view_submission",
      locale:   "en"
    ).filing_submitted

    assert_equal [@admin.email_address], mail.to
  end

  test "filing_submitted subject includes entity name and period" do
    mail = AdminMailer.with(
      admin:    @admin,
      entity:   @entity,
      scheme:   "gb_self_employment",
      start_d:  Date.new(2026, 1, 1),
      end_d:    Date.new(2026, 3, 31),
      view_url: "https://accounts.example.com/entities/1/hmrc_view_submission",
      locale:   "en"
    ).filing_submitted

    assert_includes mail.subject, @entity.name
    assert_includes mail.subject, "01 Jan 2026"
  end

  test "filing_submitted body includes view url" do
    view_url = "https://accounts.example.com/entities/1/hmrc_view_submission"
    mail = AdminMailer.with(
      admin:    @admin,
      entity:   @entity,
      scheme:   "gb_self_employment",
      start_d:  Date.new(2026, 1, 1),
      end_d:    Date.new(2026, 3, 31),
      view_url: view_url,
      locale:   "en"
    ).filing_submitted

    full_body = mail.body.parts.map { |p| p.body.to_s }.join
    assert_includes full_body, view_url
  end

  test "filing_submitted carries no attachment (link only)" do
    mail = AdminMailer.with(
      admin:    @admin,
      entity:   @entity,
      scheme:   "gb_self_employment",
      start_d:  Date.new(2026, 1, 1),
      end_d:    Date.new(2026, 3, 31),
      view_url: "https://accounts.example.com/entities/1/filing/view",
      locale:   "en"
    ).filing_submitted

    assert_empty mail.attachments
  end

  # ==================== weekly_status ====================

  def finding(area, ok, detail = "…")
    Maintenance::WeeklyCheck::Finding.new(area: area, ok: ok, detail: detail)
  end

  # THE LOAD-BEARING TEST. The report exists so that a MISSING Monday means
  # something, and that only works if a good week still sends. The obvious
  # "optimisation" — only mail when something is wrong — turns this back into an
  # alert-on-failure job, which is silent when all is well and silent when it is
  # dead.
  test "a week with nothing wrong still sends mail" do
    mail = AdminMailer.with(findings: [ finding("Backups", true), finding("Background jobs", true) ]).weekly_status

    assert_not_nil mail.to
    assert_includes mail.subject, "all clear"
    assert_includes mail.text_part.body.to_s, "Nothing needs attention"
  end

  test "the subject counts the problems, so a bad week is visible unopened" do
    mail = AdminMailer.with(findings: [ finding("Backups", false), finding("Exchange rates", false), finding("Background jobs", true) ]).weekly_status

    assert_includes mail.subject, "⚠️"
    assert_includes mail.subject, "2 problems"
  end

  test "one problem is not called problems" do
    mail = AdminMailer.with(findings: [ finding("Backups", false) ]).weekly_status

    assert_includes mail.subject, "1 problem"
    assert_not_includes mail.subject, "problems"
  end

  # The detail IS the mail. An area name on its own says "something about
  # backups" and sends you to the server to find out what.
  test "both parts carry every finding's detail" do
    findings = [ finding("Backups", false, "bucket is EMPTY"), finding("Background jobs", true, "no failed jobs") ]
    mail = AdminMailer.with(findings: findings).weekly_status

    [ mail.text_part, mail.html_part ].each do |part|
      assert_includes part.body.to_s, "bucket is EMPTY"
      assert_includes part.body.to_s, "no failed jobs"
    end
  end

  # Operational mail must never reach whoever wrote the source file.
  test "weekly_status goes to this installation's own owners" do
    mail = AdminMailer.with(findings: [ finding("Backups", true) ]).weekly_status

    assert_equal Admin.owner_addresses, mail.to
    assert_not_includes mail.to.join(" "), "wwwebsites", "an address from the author's installation"
  end

  # These alerts are the only warning that something has quietly stopped — a
  # backup, a rate feed, a scheduled job. Reaching only one of two owners, or
  # nobody at all, is the failure this guards against.

  def second_owner
    a = Admin.new(username: "second_owner", sudo: true, email_address: "second@example.org")
    a.password = "password123"
    a.save!
    a
  end

  # ⚠️ THE REGRESSION. Six callers used `Admin.find_by(sudo: true)`, which picks
  # the lowest id, so a second owner silently never heard about anything.
  test "every owner gets the operational alerts, not just the first" do
    second_owner
    expected = Admin.where(sudo: true).order(:id).pluck(:email_address)
    assert_operator expected.size, :>, 1, "precondition: more than one owner with an address"

    findings = [ Maintenance::WeeklyCheck::Finding.new(area: "Backups", ok: true, detail: "fine") ]

    assert_equal expected, AdminMailer.with(findings: findings).weekly_status.to
    assert_equal expected, AdminMailer.with(source: "ecb", error: "boom").exchange_rates_fetch_failed.to
    assert_equal expected, AdminMailer.with(error: "boom").hmrc_sandbox_check_failed.to
    assert_equal expected, AdminMailer.with(entities: []).entities_due_for_deletion.to
  end

  # Guarding with `next unless sudo_admin` threw the alert away on an
  # installation with no owner on file — silence exactly where an alarm was due.
  # The address configured for the installation is the backstop.
  test "with no owner address the alert still goes to the installation's own address" do
    Admin.where(sudo: true).update_all(email_address: nil)

    assert_equal [ CONTACT_EMAIL ], Admin.owner_addresses
    assert_equal [ CONTACT_EMAIL ], AdminMailer.with(entities: []).entities_due_for_deletion.to
  end

  # ==================== email_verification ====================
  #
  # Asserted on entity codes, names and the access labels rather than on the
  # new invite strings: those keys are not in the locale files yet (they are in
  # docs/gitignored/translations.md), and what matters here is that the mail
  # CARRIES the grant, not how it is worded.

  def draft_with_access(level: :read_only)
    draft = Admin.create!(username: "invitee_#{SecureRandom.hex(4)}",
                          email_address: "invitee_#{SecureRandom.hex(4)}@example.com",
                          password: "grantergiven1",
                          terms_agreed_version: Admin::TERMS_VERSION,
                          terms_agreed_at: Time.current)
    AdminEntity.create!(admin: draft, entity: entities(:personal), access_level: level)
    draft
  end

  test "a draft coadmin is told which books and at what level before being asked to confirm" do
    draft = draft_with_access
    assert draft.draft?, "precondition: unclaimed, so still a draft"

    mail = AdminMailer.with(admin: draft, granter: admins(:one), locale: "en").email_verification
    body = mail.text_part.body.to_s

    assert_includes body, admins(:one).email_address, "the mail must say who granted it"
    assert_includes body, entities(:personal).code
    assert_includes body, entities(:personal).name
    assert_includes body, I18n.t("access.read_only")

    # Not the wording — the keys are still pending — but an invitation and a
    # bare "confirm your address" must not arrive under the same subject line.
    plain = AdminMailer.with(admin: admins(:one), locale: "en").email_verification
    assert_not_equal plain.subject, mail.subject
  end

  test "the level named is the one actually granted, not a default" do
    draft = draft_with_access(level: :upload_receipts)

    body = AdminMailer.with(admin: draft, granter: admins(:one), locale: "en")
                      .email_verification.text_part.body.to_s

    assert_includes     body, I18n.t("access.upload_receipts")
    assert_not_includes body, I18n.t("access.read_only")
  end

  # GatesController#claim_resend sends this to the draft themselves, and
  # nothing records who granted a link. The grant still has to be visible.
  test "a draft's own resend still lists the books, with no granter to name" do
    draft = draft_with_access

    body = AdminMailer.with(admin: draft, locale: "en").email_verification.text_part.body.to_s

    assert_includes body, entities(:personal).code
    assert_includes body, I18n.t("access.read_only")
  end

  # An admin confirming an address they changed themselves is not being
  # granted anything, and their existing entities are none of this mail's
  # business.
  test "a claimed admin confirming a changed address gets no grant list" do
    admin = admins(:one)
    assert_not admin.draft?, "precondition: claimed"
    assert admin.admin_entities.any?, "precondition: holds entities that must NOT be listed"

    body = AdminMailer.with(admin: admin, locale: "en").email_verification.text_part.body.to_s

    admin.admin_entities.includes(:entity).each do |ae|
      assert_not_includes body, ae.entity.name,
        "a plain address confirmation must not enumerate the admin's books"
    end
  end

  # The link has to outlive the draft it unlocks; at 24 hours it did not.
  test "the verification link is valid as long as the draft itself" do
    draft = draft_with_access
    token = draft.generate_token_for(:email_verification)

    travel (Admin::UNCLAIMED_LIFETIME - 1.day) do
      assert_equal draft, Admin.find_by_token_for(:email_verification, token)
    end
    travel (Admin::UNCLAIMED_LIFETIME + 1.day) do
      assert_nil Admin.find_by_token_for(:email_verification, token)
    end
  end

  # It goes to several people now, so greeting one of them by name is wrong.
  test "operational alerts do not greet a single person by name" do
    body = AdminMailer.with(source: "ecb", error: "boom").exchange_rates_fetch_failed.text_part.body.to_s

    assert_not_includes body, "Hi "
    assert_includes body, "ecb"
  end
end
