# frozen_string_literal: true

class TaxExportJob < ApplicationJob
  queue_as :default

  # The export is built then emailed. With raise_delivery_errors on, an SMTP
  # failure raises rather than vanishing — retry it, and a persistent failure
  # lands in solid_queue_failed_executions. The user can also re-trigger from
  # the report.
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  # Launched from a saved report and follows it — one report, one account set.
  # The email carries TWO views of that one set:
  #
  # · summary — the account/category totals, what goes in the boxes
  # · detail  — the same, plus every transaction, with receipt links
  #
  # Both come from the SAME presenter (Reports::TaxReport for a tax report,
  # Reports::CustomReport otherwise), so the detail always foots to the summary
  # and, for a tax report, both match what the submission carries. A DATEV or
  # accountant file is added when the entity's accountant asked for one.
  # I18n.locale is ambient, thread-local state — nothing sets it for a job the
  # way a request's around_action does, so every t()/I18n.l inside the CSVs
  # below (column headings, section labels) rendered in the WORKER's locale,
  # not the admin's, until this wrapped the whole body.
  def perform(admin_id:, report_id:, locale: I18n.default_locale.to_s, display_currency: nil)
    I18n.with_locale(locale) { perform_export(admin_id, report_id, locale, display_currency) }
  end

  private

  def perform_export(admin_id, report_id, locale, display_currency)
    admin  = Admin.find(admin_id)
    report = Report.find(report_id)
    group  = report.report_group
    entity = group.entity

    # No request here, so CurrencyConfig cannot see the admin — hand it their
    # number format so the CSVs read the way their screen does. Reset around the
    # job by ActiveSupport::CurrentAttributes.
    Current.number_format = admin.preferred_number_format

    display_currency = group.display_currency || display_currency || "EUR"
    tax             = report.tax_report?
    presenter_class = tax ? Reports::TaxReport : Reports::CustomReport
    csv_class       = tax ? Reports::TaxReportCsv : Reports::StandardCsv

    summary = presenter_class.new(report: report, display_currency: display_currency,
                                  short_version: true,  admin: admin).generate
    detail  = presenter_class.new(report: report, display_currency: display_currency,
                                  short_version: false, admin: admin).generate

    receipts, unlinked = receipt_data(report, entity)

    if summary[:currencies].blank? && unlinked.empty?
      AdminMailer.with(admin: admin, entity: entity, start_date: report.start_date,
                       end_date: report.end_date, locale: locale)
                 .tax_export_empty.deliver_now
      return
    end

    slug  = tax ? "#{group.tax_scheme}-#{entity.code}" : report.name.parameterize
    range = "#{report.start_date}-#{report.end_date}"

    attachments = {}
    summary_csv = csv_class.new(report: report, data: summary, display_currency: display_currency,
                                short_version: true).generate
    attachments["#{slug}-#{range}-summary.csv"] = summary_csv

    # Insurance against reassigning an account later: the box totals as they
    # stood the moment this went out, so an old export stays checkable even
    # after the live report has drifted from it.
    #
    # Only the totals, not the transaction detail — the same scope
    # Filing::Storage backs up for a filed submission. Only written when it
    # actually differs from the last one on file, so re-exporting unchanged
    # figures never grows this list.
    if tax && summary_csv != TaxExportStorage.latest_content(report.id)
      TaxExportStorage.upload(TaxExportStorage.key_for(report.id, Time.current), summary_csv)
    end

    detail_filename = "#{slug}-#{range}-detail.csv"
    attachments[detail_filename] =
      csv_class.new(report: report, data: detail, display_currency: display_currency,
                    short_version: false, receipts: receipts, unlinked_receipts: unlinked).generate

    # The accountant's own format, if they asked for one. A stated preference on
    # the entity, never inferred from where the business is.
    if (format = AccountantExports::Base.for(entity.accountant_export))
      attachments[format.filename] = format.new(
        postings: datev_postings(report), entity: entity,
        start_date: report.start_date, end_date: report.end_date
      ).generate
    end

    AdminMailer.with(
      admin: admin, entity: entity,
      start_date: report.start_date, end_date: report.end_date,
      attachments: attachments, receipt_filename: detail_filename, locale: locale
    ).tax_export_ready.deliver_now
  end

  # { posting_id => [url] } for receipts on this report's accounts, and the
  # unlinked receipts for the period as [{ date:, title:, url: }].
  def receipt_data(report, entity)
    account_ids = report.accounts.pluck(:id)

    posting_ids = Posting.joins(:journal_entry)
      .where(account_id: account_ids)
      .where(journal_entries: { posted: true, entry_date: report.start_date..report.end_date })
      .where("journal_entries.closing_entry IS NOT TRUE")
      .pluck(:id)

    linked = Receipt.where(posting_id: posting_ids)
      .group_by(&:posting_id)
      .transform_values { |rs| rs.map { |r| receipt_url(r) }.reject(&:blank?) }

    unlinked = Receipt.where(entity_id: entity.id, posting_id: nil)
      .where(receipt_date: report.start_date..report.end_date)
      .order(:receipt_date)
      .map { |r| { date: r.receipt_date, title: r.title, url: receipt_url(r) } }

    [ linked, unlinked ]
  end

  # The nominal-leg postings behind this report, with their entries and
  # receipts eager-loaded, for a DATEV / accountant export.
  def datev_postings(report)
    Posting.joins(:journal_entry)
      .where(account_id: report.accounts.pluck(:id))
      .where(journal_entries: { posted: true, entry_date: report.start_date..report.end_date })
      .where("journal_entries.closing_entry IS NOT TRUE")
      .includes(:account, :receipts, journal_entry: { postings: :account })
      .order("journal_entries.entry_date")
  end

  def receipt_url(receipt)
    url_helpers = Rails.application.routes.url_helpers
    host_opts   = Rails.application.config.action_mailer.default_url_options || { host: "localhost" }
    sgid        = receipt.signed_id(expires_in: 30.days, purpose: :download)
    url_helpers.download_receipt_url(receipt, locale: I18n.locale, sgid: sgid, **host_opts)
  rescue => e
    Rails.logger.error "TaxExportJob#receipt_url failed for Receipt #{receipt.id}: #{e.class}: #{e.message}"
    ""
  end
end
