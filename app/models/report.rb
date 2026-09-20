# frozen_string_literal: true

class Report < ApplicationRecord

  belongs_to :report_group, 
             class_name: 'ReportGroup', 
             foreign_key: :report_group_id
  delegate :account_ids_ordered, :tax_report?, :tax_scheme, to: :report_group

  # A tax report's accounts are derived from its scheme; a custom report's are
  # the curated list. Both answer here, so callers need not know which they
  # hold.
  #
  # A tax report is scoped to its own period: the scheme's active accounts plus
  # any inactive one with posted activity in the report's dates, so a tax-
  # relevant figure is never dropped just because the account was retired.
  def accounts
    return report_group.accounts_scope unless tax_report?
    report_group.accounts_for_period(from: start_date, to: end_date)
  end
  validates :name, presence: true
  validates :start_date, presence: true
  validates :end_date, presence: true
  validate :end_date_after_start_date

private

  def end_date_after_start_date
    return unless start_date && end_date

    if end_date <= start_date
      errors.add(:end_date, I18n.t("reports.errors.end_date_after_start"))
    end
  end

end
