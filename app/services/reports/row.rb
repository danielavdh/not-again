# frozen_string_literal: true

module Reports
  # One row of the combined Reports listing: a saved Report and a downloadable
  # archive render in the same table, so both are normalised to this shape
  # rather than the view branching on two different AR/non-AR objects.
  #
  # Holds the underlying records, not built path strings. This app scopes routes
  # under a locale segment, and Rails.application.routes.url_helpers — the only
  # path-building available outside a controller or view — resolves a single
  # positional argument against the FIRST dynamic segment, :locale, not :id,
  # producing a route error. Path helpers stay in the view, called on these
  # records.
  Row = Struct.new(:entity_label, :group_label, :report_group, :name,
                    :report, :period_start, :period_end,
                    :kind, :archive_key, :year_end, :tax_export_backups, keyword_init: true) do
    def archive? = kind == :archive
    def year_end? = !!year_end

    def self.from_report(report)
      entity = report.report_group&.entity
      new(entity_label: [ entity&.code, entity&.name ].compact.join(" "),
          group_label: report.report_group&.display_name, report_group: report.report_group,
          name: report.name, report: report,
          period_start: report.start_date, period_end: report.end_date,
          kind: :report, tax_export_backups: [])
    end

    # entity_or_family_label is the entity's own name normally, or its
    # consolidation group's name when the archive is shared across a family —
    # the same distinction _overview.html.erb draws for report rows.
    def self.from_archive(entity_or_family_label:, entity_code:, entry:)
      new(entity_label: [ entity_code, entity_or_family_label ].compact.join(" "),
          group_label: I18n.t("reports.index.archive_group"), report_group: nil,
          name: entry.end_date.strftime("%y-%m-%d"), report: nil,
          period_start: nil, period_end: entry.end_date,
          kind: :archive, archive_key: entry.key, year_end: entry.year_end, tax_export_backups: [])
    end
  end
end
