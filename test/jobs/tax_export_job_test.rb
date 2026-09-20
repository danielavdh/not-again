# frozen_string_literal: true

require "test_helper"
require "csv"

class TaxExportJobTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @admin  = admins(:two)
    @entity = entities(:family_biz) # code 10
    @income  = accounts(:income_sales)
    @expense = accounts(:expenses_general)
    @fees    = accounts(:expenses_fees)

    @group = ReportGroup.create!(name: "Accountant pack", entity: @entity)
    [ @income, @expense, @fees ].each_with_index do |a, i|
      ReportGroupAccount.create!(report_group: @group, account: a, position: i)
    end
    @report = @group.reports.create!(
      name: "FY export", start_date: Date.current.beginning_of_year, end_date: Date.current.end_of_year
    )

    ActionMailer::Base.deliveries.clear
    @tax_backup_report_ids = []
  end

  teardown do
    @tax_backup_report_ids.each { |id| FileUtils.rm_rf(Rails.root.join("public", "uploads", "tax_exports", id.to_s)) }
  end

  def run_job(report: @report, **opts)
    TaxExportJob.new.perform(admin_id: @admin.id, report_id: report.id, locale: "en", **opts)
    ActionMailer::Base.deliveries.last
  end

  def attachment(mail, containing:)
    mail.attachments.find { |a| a.filename.include?(containing) }
  end

  # ---------------------------------------------------------------- empty ----

  test "an empty report sends the empty notice, no attachments" do
    empty_group  = ReportGroup.create!(name: "Nothing", entity: entities(:standalone))
    empty_report = empty_group.reports.create!(name: "x", start_date: Date.current.beginning_of_year, end_date: Date.current.end_of_year)

    mail = run_job(report: empty_report)
    assert_includes mail.subject, entities(:standalone).name
    assert_equal 0, mail.attachments.count
  end

  # -------------------------------------------------------- summary + detail
  # ----

  test "the email carries a summary file and a detail file, both from the one report" do
    mail = run_job
    names = mail.attachments.map(&:filename)
    assert names.any? { |n| n.end_with?("-summary.csv") }, names.inspect
    assert names.any? { |n| n.end_with?("-detail.csv") },  names.inspect
  end

  # The two files are two views of one set of figures — the detail's account
  # totals must equal the summary's, to the penny.
  test "detail account totals foot to the summary" do
    mail = run_job
    summary = CSV.parse(attachment(mail, containing: "-summary.csv").body.decoded, col_sep: CurrencyConfig.csv_separator)
    detail  = CSV.parse(attachment(mail, containing: "-detail.csv").body.decoded,  col_sep: CurrencyConfig.csv_separator)

    # The summary lists each account on one line (code, name, amount…). The
    # detail closes each account with a "Total <name>" row. Same number.
    last_value = ->(row) { row&.map(&:to_s)&.reject(&:empty?)&.last }
    summary_amount = ->(code) { last_value.call(summary.find { |r| r.first == code }) }
    detail_total   = ->(name) { last_value.call(detail.find  { |r| r.any? { |c| c.to_s == "Total #{name}" } }) }

    checked = 0
    [ @income, @expense, @fees ].each do |a|
      s = summary_amount.call(a.code)
      next unless s
      assert_equal s, detail_total.call(a.name), "#{a.code} #{a.name}"
      checked += 1
    end
    assert_operator checked, :>, 0, "no accounts with activity to check"
  end

  # ------------------------------------------------------------- receipts ----

  test "the detail file has a ReceiptURL column and the summary does not" do
    mail = run_job
    detail_header  = CSV.parse(attachment(mail, containing: "-detail.csv").body.decoded, col_sep: CurrencyConfig.csv_separator).find { |r| r.include?("ReceiptURL") }
    summary_rows   = CSV.parse(attachment(mail, containing: "-summary.csv").body.decoded, col_sep: CurrencyConfig.csv_separator)
    assert detail_header, "detail file is missing the ReceiptURL column"
    assert summary_rows.none? { |r| r.include?("ReceiptURL") }, "summary file should not carry receipt links"
  end

  test "receipt links use the mailer host and one posting's many receipts share one cell" do
    receipts(:linked_receipt).update!(posting_id: postings(:deposit_income).id)
    receipts(:second_unlinked_receipt).update!(posting_id: postings(:deposit_income).id)

    mail = run_job
    rows = CSV.parse(attachment(mail, containing: "-detail.csv").body.decoded, col_sep: CurrencyConfig.csv_separator)
    urls = rows.flatten.compact.select { |c| c.to_s.start_with?("http") }
    assert urls.any?, "expected receipt URLs in the detail file"

    host = Rails.application.config.action_mailer.default_url_options[:host]
    urls.flat_map { |c| c.split("\n") }.each { |u| assert_equal host, URI.parse(u).host, u }

    # both receipts land in one cell, not two rows
    multi = rows.find { |r| r.any? { |c| c.to_s.count("\n") >= 1 && c.to_s.include?("http") } }
    assert multi, "two receipts on one posting should be newline-joined in a single cell"
  end

  test "unlinked receipts for the period are listed in the detail file" do
    mail = run_job
    body = attachment(mail, containing: "-detail.csv").body.decoded
    assert_includes body, receipts(:unlinked_receipt).title
  end

  # --------------------------------------------------------------- signs ----

  test "a normal expense reads positive and an income refund negative in the detail" do
    refund = JournalEntry.new(entry_date: Date.current, memo: "Income refund", posted: true)
    refund.postings.build(account: accounts(:bank_gbp),  entry_type: :credit, amount: 2000, currency: "GBP")
    refund.postings.build(account: @income,               entry_type: :debit,  amount: 2000)
    refund.save!

    mail = run_job
    rows = CSV.parse(attachment(mail, containing: "-detail.csv").body.decoded, col_sep: CurrencyConfig.csv_separator)

    amount_cell = ->(memo) {
      row = rows.find { |r| r.any? { |c| c.to_s.include?(memo) } && r.none? { |c| c.to_s.start_with?("Total ") } }
      row&.reverse&.find { |c| c.to_s =~ /\d/ }
    }
    assert_not amount_cell.call("Test withdrawal").to_s.start_with?("-"), "a normal expense is positive"
    assert amount_cell.call("Income refund").to_s.start_with?("-"), "an income refund is negative"
  end

  # ---------------------------------------------------------------- DATEV ----

  test "DATEV is attached only when the entity's accountant asked for it" do
    assert_nil attachment(run_job, containing: "EXTF_Buchungsstapel")

    @entity.update!(accountant_export: "datev")
    assert attachment(run_job, containing: "EXTF_Buchungsstapel"), "DATEV attachment missing"
  ensure
    @entity.update!(accountant_export: nil)
  end

  # ----------------------------------------------------------- tax report ----

  test "a tax report's summary is grouped into the scheme's categories" do
    Dir[Rails.root.join("db/tax_categories/gb_self_employment*.yml")].each { |f| TaxCategoryLoader.call(f) }
    @entity.update!(tax_schemes: %w[gb_self_employment])
    @income.update!(tax_scheme: "gb_self_employment", tax_category_key: "sales_income")

    tax_group  = ReportGroup.create!(name: "GB SE", entity: @entity, tax_scheme: "gb_self_employment")
    tax_report = tax_group.reports.create!(name: "SE", start_date: Date.current.beginning_of_year, end_date: Date.current.end_of_year)

    mail = run_job(report: tax_report)
    part = attachment(mail, containing: "-summary.csv")
    assert_includes part.filename, "gb_self_employment", "the scheme belongs in the filename"
    cat = TaxCategory.find_by(scheme: "gb_self_employment", key: "sales_income")
    assert_includes part.body.decoded, cat.label, "the category label should head its accounts"
  ensure
    @income.update!(tax_scheme: nil, tax_category_key: nil)
    @entity.update!(tax_schemes: [])
  end

  # ------------------------------------------------------------ backups ----

  def build_tax_report(scheme: "gb_self_employment")
    Dir[Rails.root.join("db/tax_categories/#{scheme}*.yml")].each { |f| TaxCategoryLoader.call(f) }
    @entity.update!(tax_schemes: [ scheme ])
    @income.update!(tax_scheme: scheme, tax_category_key: "sales_income")

    tax_group = ReportGroup.create!(name: "GB SE backups", entity: @entity, tax_scheme: scheme)
    tax_report = tax_group.reports.create!(
      name: "SE", start_date: Date.current.beginning_of_year, end_date: Date.current.end_of_year
    )
    @tax_backup_report_ids << tax_report.id
    tax_report
  end

  test "a tax export backs up its summary CSV" do
    tax_report = build_tax_report
    run_job(report: tax_report)

    backups = TaxExportStorage.list(tax_report.id)
    assert_equal 1, backups.size
    assert_equal TaxExportStorage.read(backups.first.key), TaxExportStorage.latest_content(tax_report.id)
  ensure
    @income.update!(tax_scheme: nil, tax_category_key: nil)
    @entity.update!(tax_schemes: [])
  end

  test "re-exporting unchanged figures does not grow the backup list" do
    tax_report = build_tax_report
    run_job(report: tax_report)
    run_job(report: tax_report)
    run_job(report: tax_report)

    assert_equal 1, TaxExportStorage.list(tax_report.id).size
  ensure
    @income.update!(tax_scheme: nil, tax_category_key: nil)
    @entity.update!(tax_schemes: [])
  end

  test "re-exporting after the figures genuinely change adds a second backup" do
    tax_report = build_tax_report
    run_job(report: tax_report)
    assert_equal 1, TaxExportStorage.list(tax_report.id).size

    # A genuine change to the same category's total — not a re-tag, just more
    # activity landing in the period before the second export.
    je = JournalEntry.new(entry_date: Date.current, memo: "More sales", posted: true)
    je.postings.build(account: accounts(:bank_gbp), entry_type: :debit,  amount: 999, currency: "GBP")
    je.postings.build(account: @income,             entry_type: :credit, amount: 999)
    je.save!

    run_job(report: tax_report)

    assert_equal 2, TaxExportStorage.list(tax_report.id).size
  ensure
    @income.update!(tax_scheme: nil, tax_category_key: nil)
    @entity.update!(tax_schemes: [])
  end

  test "a custom report's export is never backed up" do
    run_job # @report from setup has no tax_scheme
    assert_empty TaxExportStorage.list(@report.id)
  end

  test "the export never reaches outside the report's own accounts" do
    other = Account.create!(code: "410099", name: "Not in the report", account_type: :income)
    je = JournalEntry.new(entry_date: Date.current, memo: "elsewhere", posted: true)
    je.postings.build(account: accounts(:bank_gbp), entry_type: :debit,  amount: 4200, currency: "GBP")
    je.postings.build(account: other,               entry_type: :credit, amount: 4200)
    je.save!

    body = attachment(run_job, containing: "-detail.csv").body.decoded
    assert_not_includes body, "410099"
  end

  # -------------------------------------------------------------- A9: locale
  # ----

  # I18n.locale is ambient — a job has no request setting it, so this asserts
  # against explicit :de/:en options, never against whatever the test process
  # happens to be running under.
  test "the CSV labels follow the locale the job was handed, not the worker's ambient one" do
    tax_report = build_tax_report

    TaxExportJob.new.perform(admin_id: @admin.id, report_id: tax_report.id, locale: "de")
    body = ActionMailer::Base.deliveries.last.attachments.find { |a| a.filename.end_with?("-summary.csv") }.body.decoded

    assert_includes body, I18n.t("reports.show.category", locale: :de)
    assert_not_includes body, I18n.t("reports.show.category", locale: :en)
  end

  test "the CSV number format follows the locale the job was handed" do
    mail = run_job # @report from setup, GBP figures, no explicit preferred_number_format
    en_body = attachment(mail, containing: "-detail.csv").body.decoded

    ActionMailer::Base.deliveries.clear
    TaxExportJob.new.perform(admin_id: @admin.id, report_id: @report.id, locale: "de")
    de_body = attachment(ActionMailer::Base.deliveries.last, containing: "-detail.csv").body.decoded

    assert_equal CurrencyConfig.csv_separator(locale: :en), ","
    assert_equal CurrencyConfig.csv_separator(locale: :de), ";"
    assert CSV.parse(en_body, col_sep: ",").any?, "english export must be comma-separated"
    assert CSV.parse(de_body, col_sep: ";").any?, "german export must be semicolon-separated"
  end

  # I18n.with_locale must not leak into whatever runs next in the same worker.
  test "the job restores the ambient locale when it finishes" do
    I18n.locale = :en
    TaxExportJob.new.perform(admin_id: @admin.id, report_id: @report.id, locale: "de")
    assert_equal :en, I18n.locale
  end
end
