# frozen_string_literal: true

class Report < ApplicationRecord

  belongs_to :report_group, 
             class_name: 'ReportGroup', 
             foreign_key: :report_group_id
  delegate :account_ids_ordered, :tax_report?, :vat_report?, :tax_scheme, to: :report_group

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
  # Basis points. A flat rate is a whole-percent-or-half figure in practice, but
  # the column is bps so it cannot drift from tax_codes.rate_bps.
  validates :flat_rate_bps, numericality: { only_integer: true, in: 1..10_000 },
                            allow_nil: true

  # The form asks for a PERCENTAGE, because that is what the scheme is quoted in
  # and what the user reads off HMRC's list. The column is basis points so it
  # cannot drift from tax_codes.rate_bps. Point-only, like the exchange-rate
  # field: an HTML5 number input takes "." whatever the admin's number format.
  def flat_rate_percentage
    flat_rate_bps && flat_rate_bps / 100.0
  end

  def flat_rate_percentage=(value)
    self.flat_rate_bps = value.presence && (value.to_f * 100).round
  end
  validate :end_date_after_start_date

private

  def end_date_after_start_date
    return unless start_date && end_date

    if end_date <= start_date
      errors.add(:end_date, I18n.t("reports.errors.end_date_after_start"))
    end
  end

end
