# frozen_string_literal: true
require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:two)
    @entity = entities(:family_biz)
    @group = ReportGroup.create!(name: "Test Reports Group", entity: @entity)
    @report = @group.reports.create!(
      name: "Q1 2026",
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 3, 31)
    )
    sign_in_as(@admin)
  end

  # --- Index ---

  test "should get index" do
    get reports_url(locale: :en)
    assert_response :success
  end

  # --- Show ---

  test "should show report" do
    get report_url(@report, locale: :en)
    assert_response :success
  end

  # A saved report with a currency it has no rate for blanks the WHOLE converted
  # column, like the three general reports, rather than showing a total
  # understated by the untranslatable postings.
  test "a saved report with a missing rate shows no converted figures, only the reason" do
    ExchangeRate.where(from_currency: %w[EUR GBP], to_currency: %w[EUR GBP]).delete_all

    eur_bank = Account.create!(code: "1#{@entity.code}950", name: "EUR bank", account_type: :asset, currency: "EUR")
    gbp_bank = Account.create!(code: "1#{@entity.code}951", name: "GBP bank", account_type: :asset, currency: "GBP")
    sales    = Account.create!(code: "4#{@entity.code}950", name: "Sales", account_type: :income)
    # One sale in GBP (translatable), one in EUR (no rate) on the SAME account —
    # so without the fix the total is the GBP half, understated, not zero.
    [ [ gbp_bank, "GBP" ], [ eur_bank, "EUR" ] ].each do |bank, cur|
      je = JournalEntry.new(entry_date: Date.new(2026, 2, 1), posted: true, memo: "#{cur} sale")
      je.postings.build(account: bank,  entry_type: :debit,  amount: 50_000, currency: cur)
      je.postings.build(account: sales, entry_type: :credit, amount: 50_000)
      je.save!
    end

    report = @group.reports.create!(name: "EUR report", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31))
    ReportGroupAccount.create!(report_group: @group, account: sales, position: 1)

    data = Reports::CustomReport.new(report: report, display_currency: "GBP", admin: @admin, sources: [ "ecb" ]).generate

    assert data[:rate_unavailable], "the missing rate must be recorded"
    translated = data[:parent_groups].flat_map { |g| g[:accounts].map { |a| a[:translated_total] } }
    assert translated.all?(&:zero?), "every converted figure must be blanked, got #{translated.inspect}"
  end

  test "show as CSV" do
    get report_url(@report, locale: :en, format: :csv)
    assert_response :success
    assert_match "text/csv", response.content_type
  end

  # --- Tax report (grouped by category, single CSV button) ---

  def tax_report_fixture
    Dir[Rails.root.join("db/tax_categories/gb_self_employment*.yml")].each { |f| TaxCategoryLoader.call(f) }
    @entity.update!(tax_schemes: %w[gb_self_employment])
    accounts(:income_sales).update!(tax_scheme: "gb_self_employment", tax_category_key: "sales_income")
    grp = ReportGroup.create!(name: "GB SE", entity: @entity, tax_scheme: "gb_self_employment")
    grp.reports.create!(name: "SE", start_date: Date.current.beginning_of_year, end_date: Date.current.end_of_year)
  end

  test "a tax report renders grouped by category" do
    report = tax_report_fixture
    get report_url(report, locale: :en)
    assert_response :success
    assert_select "table.reports"
  end

  test "a tax report CSV is the categorised view, summary or detail per the toggle" do
    report = tax_report_fixture

    get report_url(report, locale: :en, format: :csv, version: "short")
    assert_response :success
    summary = @response.body

    get report_url(report, locale: :en, format: :csv, version: "long")
    assert_response :success
    detail = @response.body

    # detail carries the word behind the numbers that the summary does not:
    # a Date column
    assert_not_equal summary, detail
    assert_includes detail, I18n.t("attrs.date")
  end

  test "cannot show report from inaccessible entity" do
    other_entity = entities(:personal)
    other_group = ReportGroup.create!(name: "Other", entity: other_entity)
    other_report = other_group.reports.create!(
      name: "Private",
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 3, 31)
    )
    get report_url(other_report, locale: :en)
    assert_response :not_found
  end

  # --- New ---

  test "should get new" do
    get new_report_group_report_url(@group, locale: :en)
    assert_response :success
  end

  # --- Create ---

  test "should create report" do
    assert_difference("Report.count") do
      post report_group_reports_url(@group, locale: :en), params: {
        report: { name: "New Report", start_date: "2026-01-01", end_date: "2026-03-31" }
      }
    end
    assert_redirected_to dashboard_path
  end

  test "create fails without name" do
    assert_no_difference("Report.count") do
      post report_group_reports_url(@group, locale: :en), params: {
        report: { name: "", start_date: "2026-01-01", end_date: "2026-03-31" }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create fails when end_date before start_date" do
    assert_no_difference("Report.count") do
      post report_group_reports_url(@group, locale: :en), params: {
        report: { name: "Bad Dates", start_date: "2026-03-31", end_date: "2026-01-01" }
      }
    end
    assert_response :unprocessable_entity
  end

  # --- Edit / Update ---

  test "should get edit" do
    get edit_report_url(@report, locale: :en)
    assert_response :success
  end

  test "should update report" do
    patch report_url(@report, locale: :en), params: {
      report: { name: "Updated Name" }
    }
    assert_redirected_to report_url(@report, locale: :en)
    @report.reload
    assert_equal "Updated Name", @report.name
  end

  test "update fails with invalid dates" do
    patch report_url(@report, locale: :en), params: {
      report: { start_date: "2026-12-01", end_date: "2026-01-01" }
    }
    assert_response :unprocessable_entity
  end

  # --- Destroy ---

  test "should destroy report" do
    assert_difference("Report.count", -1) do
      delete report_url(@report, locale: :en)
    end
    assert_redirected_to reports_url(locale: :en)
  end

  # --- tax_export ---

  test "tax_export enqueues job and redirects" do
    assert_enqueued_with(job: TaxExportJob) do
      post tax_export_report_url(@report, locale: :en)
    end
    assert_redirected_to report_url(@report, locale: :en)
  end

  # Notifies whoever actually owns the ENTITY. A coadmin can hold access granted
  # by more than one owner, and this report belongs to family_biz, which `one` —
  # shared_reader's OTHER owner, via personal — has nothing to do with. The
  # email must go to family_biz's real full-access admins, never to `one`.
  test "tax_export notifies the entity's actual full-access admin(s)" do
    reader = admins(:shared_reader) # read_only on personal (one's) AND family_biz (two's)
    group  = ReportGroup.create!(name: "Family Biz Report", entity: entities(:family_biz))
    report = group.reports.create!(name: "Q1", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31))

    sign_in_as(reader)
    # family_biz has TWO full-access admins in the fixtures, and both must be
    # notified. Neither notification is what this test is really guarding
    # against: `one`, who owns nothing here but shares a DIFFERENT entity with
    # reader.
    assert_enqueued_email_with AdminMailer, :tax_export_triggered_by_coadmin,
                                params: { parent_admin: admins(:two), coadmin: reader, entity: entities(:family_biz),
                                          start_date: report.start_date, end_date: report.end_date, locale: "en" } do
      post tax_export_report_url(report, locale: :en)
    end
    assert_enqueued_email_with AdminMailer, :tax_export_triggered_by_coadmin,
                                params: { parent_admin: admins(:mixed), coadmin: reader, entity: entities(:family_biz),
                                          start_date: report.start_date, end_date: report.end_date, locale: "en" }

    mail_jobs = enqueued_jobs.select { |j| j[:job].to_s == "ActionMailer::MailDeliveryJob" }
    assert_equal 2, mail_jobs.size, "only family_biz's two actual full-access admins should be notified"
  end

  # --- download_tax_export_backup ---

  test "download_tax_export_backup streams back what was uploaded" do
    key = TaxExportStorage.key_for(@report.id, Time.current)
    TaxExportStorage.upload(key, "sales_income,Sales,100")

    get download_tax_export_backup_report_url(@report, key: File.basename(key), locale: :en)
    assert_response :success
    assert_includes response.body, "sales_income,Sales,100"
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "tax_exports", @report.id.to_s))
  end

  test "download_tax_export_backup refuses a report the admin cannot access" do
    other_group  = ReportGroup.create!(name: "Not mine", entity: entities(:personal))
    other_report = other_group.reports.create!(name: "x", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31))
    key = TaxExportStorage.key_for(other_report.id, Time.current)
    TaxExportStorage.upload(key, "not yours")

    get download_tax_export_backup_report_url(other_report, key: File.basename(key), locale: :en)
    assert_response :not_found
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "tax_exports", other_report.id.to_s))
  end

  test "download_tax_export_backup on a filename that was never uploaded reports not found, not a 500" do
    get download_tax_export_backup_report_url(@report, key: "26-01-01-000000-backup.csv", locale: :en)
    assert_redirected_to reports_url(locale: :en)
    assert_equal I18n.t("reports.index.not_found"), flash[:alert]
  end

  # The whole point of FILENAME_FORMAT: a traversal attempt must be rejected
  # before it is ever joined into a storage key — the same class of bug
  # download_archive and destroy_archive already had once.
  test "download_tax_export_backup rejects a key shaped to escape its own report's folder" do
    get download_tax_export_backup_report_url(@report, key: "../../../etc/passwd", locale: :en)
    assert_redirected_to reports_url(locale: :en)
    assert_equal I18n.t("reports.index.not_found"), flash[:alert]
  end

  # --- trial_balance ---

  test "trial_balance renders success" do
    get trial_balance_reports_url(locale: :en)
    assert_response :success
  end

  test "trial_balance as CSV" do
    get trial_balance_reports_url(locale: :en, format: :csv)
    assert_response :success
    assert_match "text/csv", response.content_type
  end

  # --- profit_loss ---

  test "profit_loss renders success" do
    get profit_loss_reports_url(locale: :en)
    assert_response :success
  end

  test "profit_loss as CSV" do
    get profit_loss_reports_url(locale: :en, format: :csv)
    assert_response :success
    assert_match "text/csv", response.content_type
  end

  # --- fx_variance ---

  test "fx_variance renders success" do
    get fx_variance_reports_url(locale: :en, end_date: Date.current.to_s)
    assert_response :success
  end

  test "fx_variance as CSV" do
    get fx_variance_reports_url(locale: :en, format: :csv, end_date: Date.current.to_s)
    assert_response :success
    assert_match "text/csv", response.content_type
  end

  test "fx_variance renders over an explicit period and scope" do
    get fx_variance_reports_url(locale: :en, start_date: "2026-01-01", end_date: "2026-12-31",
                               entities: @entity.code)
    assert_response :success
  end

  test "a cross-currency transfer shows on the fx_variance page and its variance line on the balance sheet" do
    ExchangeRate.where(from_currency: %w[EUR GBP], to_currency: %w[EUR GBP]).delete_all
    on = Date.current.beginning_of_month
    ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", source: "ecb", rate: 0.85,
                         effective_date: on, valid_from: on, valid_to: on.end_of_month)
    je = JournalEntry.new(entry_date: Date.current, memo: "Wise sweep", posted: true)
    je.postings.build(account: accounts(:bank_gbp), entry_type: :debit,  amount: 83_000)
    je.postings.build(account: accounts(:bank_eur), entry_type: :credit, amount: 100_000)
    je.save!
    sign_in_as(admins(:sudo))

    get fx_variance_reports_url(locale: :en, currency: "GBP", entities: "10")
    assert_response :success
    assert_match "Wise sweep", response.body

    get balance_sheet_reports_url(locale: :en, currency: "GBP", entities: "10")
    assert_response :success
    # Part of the residual is exchange variance, not profit — the breakout row
    # appears.
    assert_select "tr.fx-variance"
  end

  # --- year_end ---

  test "new_year_end shows the financial-year page for an entity already closing" do
    # family_biz's FY2024 is closed, later years empty, current one unfinished.
    get new_year_end_reports_url(locale: :en, entity_id: @entity.id)
    assert_response :success
    assert_select "form[action=?]", change_year_end_reports_path(entity_id: @entity.id)
  end

  test "create_year_end redirects without creating when there is no closeable period" do
    # family_biz's FY2024 is already closed; later years are empty and the
    # current one is unfinished — nothing to close.
    assert_no_difference "JournalEntry.count" do
      post create_year_end_reports_url(locale: :en), params: { entity_id: @entity.id }
    end
    assert_redirected_to dashboard_url(locale: :en)
  end

  # A permission case, not an empty-books one. Titled "for an entity with
  # nothing to close" it passed for the wrong reason: standalone(05) is nobody's
  # entity, the lookup raised RecordNotFound inside the action, and
  # create_year_end's blanket rescue turned that into the generic year-end
  # alert.
  test "create_year_end refuses an entity the admin does not hold" do
    entity = entities(:standalone)
    assert_no_difference "JournalEntry.count" do
      post create_year_end_reports_url(locale: :en),
        params: { entity_id: entity.id, pattern: "calendar" }
    end
    assert_redirected_to dashboard_url(locale: :en)
    assert_equal I18n.t("access.read_only_deny"), flash[:alert]
  end

  # Two members on DIFFERENT fiscal patterns — UK Apr–Mar versus calendar.
  # Archives are per calendar year for everyone, so a single close by the last
  # sibling to cover a year lands both on one file.
  test "family members on different fiscal patterns converge on one calendar-year archive" do
    sign_in_as(admins(:sudo))
    group = EntityGroup.create!(name: "Staggered Household")

    uk_entity  = travel_to(Date.new(2020, 1, 1)) { Entity.create!(name: "UK Member", code: "94", active: true, entity_group: group) }
    cal_entity = travel_to(Date.new(2020, 1, 1)) { Entity.create!(name: "Calendar Member", code: "95", active: true, entity_group: group) }

    uk_income = Account.create!(code: "494001", name: "Sales", account_type: :income, active: true)
    uk_bank   = Account.create!(code: "194001", name: "Bank",  account_type: :asset, currency: "GBP", active: true)
    cal_income = Account.create!(code: "495001", name: "Sales", account_type: :income, active: true)
    cal_bank   = Account.create!(code: "195001", name: "Bank",  account_type: :asset, currency: "GBP", active: true)

    post_je = ->(inc, bank, date, memo, amt) {
      je = JournalEntry.new(entry_date: date, posted: true, memo: memo)
      je.postings.build(account: inc,  entry_type: :credit, amount: amt)
      je.postings.build(account: bank, entry_type: :debit,  amount: amt, currency: "GBP")
      je.save!
    }
    # Both members active across calendar 2023.
    post_je.call(uk_income,  uk_bank,  Date.new(2023, 6, 1),  "uk income 2023", 100)
    post_je.call(cal_income, cal_bank, Date.new(2023, 6, 1),  "calendar income 2023", 200)

    scope_key = Archives::Storage.scope_key_for(uk_entity.reload)

    # DE member closes FY2023 (calendar). Not the last sibling for 2023 — the
    # UK member has not closed through 2023-12-31 yet.
    travel_to(Date.new(2024, 2, 1)) do
      post create_year_end_reports_url(locale: :en), params: { entity_id: cal_entity.id, pattern: "calendar" }
    end
    assert_empty Archives::Storage.list(scope_key), "calendar 2023 not fully closed by the family yet"

    # UK member closes FY2023/24 (Apr 2023–Mar 2024) — now covers 2023-12-31.
    travel_to(Date.new(2024, 5, 1)) do
      post create_year_end_reports_url(locale: :en), params: { entity_id: uk_entity.id, pattern: "uk" }
    end
    entries = Archives::Storage.list(scope_key)
    assert_equal 1, entries.size, "both members converge on ONE file for calendar 2023"
    assert_equal 2023, entries.first.year
    content = Archives::Storage.read(entries.first.key)
    assert_includes content, "uk income 2023"
    assert_includes content, "calendar income 2023"
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "g#{group.id}")) if group
  end

  # --- create_archive / download_archive (§8) ---

  test "create_archive downloads a CSV immediately, one click" do
    post create_archive_reports_url(locale: :en), params: { entity_id: @entity.id }
    assert_response :success
    assert_match "text/csv", response.content_type
    assert_includes response.body, "EntryID,Date,Entity,AccountCode"
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", @entity.code))
  end

  # The manual button snapshots this scope's CURRENT calendar year, up to
  # today — a deletable convenience copy, not the permanent record.
  test "create_archive covers the current calendar year up to today" do
    entity = travel_to(Date.new(2020, 1, 1)) { Entity.create!(name: "Manual Snapshot Ltd", code: "77", active: true) }
    bank   = Account.create!(code: "177001", name: "Bank",   account_type: 1, currency: "GBP", active: true)
    income = Account.create!(code: "477001", name: "Sales",  account_type: 4, active: true)

    this_year = JournalEntry.new(entry_date: Date.new(Date.current.year, 2, 1), memo: "Sale this year", posted: true)
    this_year.postings.build(account: bank,   entry_type: :debit,  amount: 5_000, currency: "GBP")
    this_year.postings.build(account: income, entry_type: :credit, amount: 5_000)
    this_year.save!

    last_year = JournalEntry.new(entry_date: Date.new(Date.current.year - 1, 6, 1), memo: "Sale last year", posted: true)
    last_year.postings.build(account: bank,   entry_type: :debit,  amount: 1_000, currency: "GBP")
    last_year.postings.build(account: income, entry_type: :credit, amount: 1_000)
    last_year.save!

    sign_in_as(admins(:sudo))
    post create_archive_reports_url(locale: :en), params: { entity_id: entity.id }

    assert_response :success
    assert_includes response.body, "Sale this year"
    assert_not_includes response.body, "Sale last year", "the snapshot is this calendar year only"
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "77"))
  end

  test "create_archive refuses an entity the admin does not hold" do
    entity = entities(:standalone)
    post create_archive_reports_url(locale: :en), params: { entity_id: entity.id }
    assert_redirected_to dashboard_url(locale: :en)
    assert_equal I18n.t("access.read_only_deny"), flash[:alert]
  end

  test "download_archive streams back what was uploaded" do
    key = Archives::Generate.call(scope_key: Archives::Storage.scope_key_for(@entity.reload), year: Date.current.year, year_end: true)
    get download_archive_reports_url(locale: :en, key: key.delete_prefix("archives/"))
    assert_response :success
    assert_includes response.body, "EntryID,Date,Entity,AccountCode"
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", @entity.code))
  end

  test "download_archive refuses a key scoped to an entity the admin cannot access" do
    other = entities(:personal)
    key = Archives::Storage.key_for(other.code, Date.current)
    Archives::Storage.upload(key, "01's books")
    get download_archive_reports_url(locale: :en, key: key.delete_prefix("archives/"))
    assert_redirected_to dashboard_url(locale: :en)
    assert_equal I18n.t("access.read_only_deny"), flash[:alert]
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", other.code))
  end

  test "download_archive on a key that was never uploaded reports not found, not a 500" do
    get download_archive_reports_url(locale: :en, key: "#{@entity.code}/26-01-01-backup.csv")
    assert_redirected_to reports_url(locale: :en)
    # Not an exact I18n.t match: reports.index.not_found is a new key, listed
    # in docs/gitignored/translations.md, not yet in the real locale files —
    # see feedback_locale_edits memory.
    assert flash[:alert].present?
  end

  # --- destroy_archive ---
  #
  # Dedicated entities, one code each, rather than reusing entities(:family_biz)
  # (code "10"): other tests here and in journal_entries_controller_test.rb also
  # read, write and clean real files under public/uploads/archives/10/, and the
  # suite runs in parallel processes sharing that filesystem. Three DIFFERENT
  # codes for the same reason — these three can run in parallel with each other.
  test "destroy_archive removes an on-demand archive" do
    entity = Entity.create!(name: "Archive Delete Test", code: "91", active: true)
    AdminEntity.create!(admin: @admin, entity: entity, access_level: :full_access)
    key = Archives::Storage.key_for("91", Date.current)
    Archives::Storage.upload(key, "snapshot")

    delete destroy_archive_reports_url(locale: :en, key: key.delete_prefix("archives/"))

    assert_redirected_to reports_url(locale: :en)
    assert_empty Archives::Storage.list(Archives::Storage.scope_key_for(entity))
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "91"))
  end

  test "destroy_archive refuses a year-end archive, server-side" do
    entity = Entity.create!(name: "Archive Delete Test", code: "92", active: true)
    AdminEntity.create!(admin: @admin, entity: entity, access_level: :full_access)
    key = Archives::Storage.key_for("92", 2025, year_end: true)
    Archives::Storage.upload(key, "the permanent record")

    delete destroy_archive_reports_url(locale: :en, key: key.delete_prefix("archives/"))

    assert_redirected_to reports_url(locale: :en)
    assert_equal 1, Archives::Storage.list(Archives::Storage.scope_key_for(entity)).size,
      "a year-end archive must survive an attempt to delete it"
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "92"))
  end

  test "destroy_archive requires write access, not just read" do
    entity = Entity.create!(name: "Archive Delete Test", code: "93", active: true)
    AdminEntity.create!(admin: @admin, entity: entity, access_level: :full_access)
    key = Archives::Storage.key_for("93", Date.current)
    Archives::Storage.upload(key, "snapshot")
    no_access_admin = admins(:one) # holds only 01 and 03, never entity "93"
    sign_in_as(no_access_admin)

    delete destroy_archive_reports_url(locale: :en, key: key.delete_prefix("archives/"))

    assert_redirected_to dashboard_url(locale: :en)
    assert_equal 1, Archives::Storage.list(Archives::Storage.scope_key_for(entity)).size,
      "an admin with no access to this entity must not be able to delete its archive"
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "93"))
  end

  # --- Unauthenticated ---

  test "unauthenticated cannot access reports" do
    sign_out
    get reports_url(locale: :en)
    assert_response :redirect
  end

  # The key is a wildcard route segment, so it is attacker input in full.
  # Authorising only its first segment and concatenating the rest let
  # "10/../05/x.csv" authorise as 10 and then read — or delete — entity 05's
  # posting-level ledger.
  class ArchiveKeyTraversalTests < ActionDispatch::IntegrationTest
    # A victim entity PER TEST, not one shared fixture: these write and clean
    # real files under public/uploads/archives/<code>/, and parallel test
    # processes share that directory, so one test's teardown would delete
    # another's file mid-run — which looks exactly like the vulnerability
    # passing.
    def victim_setup(code)
      admin  = admins(:two)              # full access on 10 and 04; never on `code`
      victim = Entity.create!(name: "Traversal Victim #{code}", code: code, active: true)
      scope  = Archives::Storage.scope_key_for(victim)
      Archives::Storage.upload(Archives::Storage.key_for(scope, Date.new(2026, 1, 1)),
                               "SECRET LEDGER")
      sign_in_as(admin)
      scope
    end

    def cleanup(code)
      FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", code))
    end

    def traversals(code)
      [
        "10/../#{code}/26-01-01-backup.csv",
        "10/./../#{code}/26-01-01-backup.csv",
        "10/../../archives/#{code}/26-01-01-backup.csv"
      ]
    end

    test "download refuses every traversal shape and leaks nothing" do
      scope = victim_setup("87")
      traversals("87").each do |key|
        get download_archive_reports_url(locale: :en, key: key)
        assert_not_equal 200, response.status, "#{key} was served"
        assert_not_includes response.body.to_s, "SECRET LEDGER",
          "#{key} leaked another entity's ledger"
      end
    ensure
      cleanup("87")
    end

    test "destroy refuses every traversal shape and the file survives" do
      scope = victim_setup("68")
      traversals("68").each do |key|
        delete destroy_archive_reports_url(locale: :en, key: key)
        assert Archives::Storage.list(scope).any?,
          "#{key} deleted another entity's archive"
      end
    ensure
      cleanup("68")
    end

    # The direct, non-traversal request must still be refused — that guard
    # was always correct and must not regress while fixing the traversal.
    test "the plain foreign-scope request is still refused" do
      victim_setup("69")
      get download_archive_reports_url(locale: :en, key: "69/26-01-01-backup.csv")
      assert_redirected_to dashboard_url(locale: :en)
    ensure
      cleanup("69")
    end

    # A malformed key is a refusal, not a 500.
    test "a nonsense key is refused without raising" do
      sign_in_as(admins(:two))
      get download_archive_reports_url(locale: :en, key: "not-a-real/key")
      assert_response :redirect
    end
  end

  # Archives::BooksCsv pulls the whole family's ledger for one member's
  # scope_key, so partial access to a family must not create OR download it.
  class FamilyArchiveAccessTests < ActionDispatch::IntegrationTest
    # ⚠️ A DEDICATED id per test, for the same reason the tests above use a
    # dedicated entity CODE each — and it has to be the id, not the code,
    # because a family's archives live under `g<EntityGroup id>`.
    #
    # Parallel workers get a database each but SHARE the real disk under
    # public/uploads/archives/. Left to the sequence, every worker's first
    # EntityGroup is id 1, so all three of these tests write to `archives/g1/`
    # at once — and "create_archive is refused" asserts that directory is
    # EMPTY while "download_archive is refused" is busy putting a file in it.
    # Green alone, red at random in a full run, and only ever on the machine
    # that happened to interleave them.
    GROUP_IDS = { create: 9101, download: 9102, both: 9103 }.freeze

    def cleanup(scope_key)
      FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", scope_key))
    end

    test "create_archive is refused with access to only one family member" do
      group = EntityGroup.create!(id: GROUP_IDS[:create], name: "Family archive test create")
      e1 = Entity.create!(name: "FamC 1", code: "31", active: true, entity_group: group)
      Entity.create!(name: "FamC 2", code: "32", active: true, entity_group: group)
      admin = admins(:read_only)
      AdminEntity.create!(admin: admin, entity: e1, access_level: :read_only)
      sign_in_as(admin)

      post create_archive_reports_url(locale: :en, entity_id: e1.id)

      assert_redirected_to dashboard_url(locale: :en)
      assert_empty Archives::Storage.list("g#{group.id}")
    ensure
      cleanup("g#{group.id}")
    end

    test "download_archive is refused with write access to only one family member" do
      group = EntityGroup.create!(id: GROUP_IDS[:download], name: "Family archive test download")
      e1 = Entity.create!(name: "FamD 1", code: "33", active: true, entity_group: group)
      e2 = Entity.create!(name: "FamD 2", code: "34", active: true, entity_group: group)
      admin = admins(:two) # full_access is fixture default
      AdminEntity.create!(admin: admin, entity: e1, access_level: :full_access)
      AdminEntity.create!(admin: admin, entity: e2, access_level: :read_only) # NOT full_access
      scope_key = "g#{group.id}"
      key = Archives::Storage.key_for(scope_key, Date.new(2026, 1, 1))
      Archives::Storage.upload(key, "FAMILY LEDGER")
      sign_in_as(admin)

      get download_archive_reports_url(locale: :en, key: "#{scope_key}/#{File.basename(key)}")

      assert_redirected_to dashboard_url(locale: :en)
    ensure
      cleanup(scope_key) if scope_key
    end

    test "full access to every family member unlocks both create and download" do
      group = EntityGroup.create!(id: GROUP_IDS[:both], name: "Family archive test both")
      e1 = Entity.create!(name: "FamB 1", code: "35", active: true, entity_group: group)
      e2 = Entity.create!(name: "FamB 2", code: "36", active: true, entity_group: group)
      admin = admins(:read_only)
      AdminEntity.create!(admin: admin, entity: e1, access_level: :full_access)
      AdminEntity.create!(admin: admin, entity: e2, access_level: :full_access)
      # A little revenue so the CSV is not header-only (create_archive redirects
      # with "nothing to archive" otherwise).
      income = Account.create!(code: "435001", name: "Test Income", account_type: :income, active: true)
      bank   = Account.create!(code: "135002", name: "Test Bank", account_type: :asset, active: true, currency: "GBP")
      je = JournalEntry.new(entry_date: Date.current, memo: "seed", posted: true)
      je.postings.build(account: bank,   entry_type: :debit,  amount: 100, currency: "GBP")
      je.postings.build(account: income, entry_type: :credit, amount: 100, currency: "GBP")
      je.save!
      sign_in_as(admin)
      scope_key = "g#{group.id}"

      post create_archive_reports_url(locale: :en, entity_id: e1.id)
      assert_response :success
      assert_equal 1, Archives::Storage.list(scope_key).size
    ensure
      cleanup(scope_key) if scope_key
    end
  end

end
