# frozen_string_literal: true

class Report < ApplicationRecord

  belongs_to :report_group, 
             class_name: 'ReportGroup', 
             foreign_key: :report_group_id
  delegate :account_ids_ordered, :tax_report?, :vat_report?, :tax_scheme, to: :report_group

  # The clearing entry booked when this VAT return was marked final.
  has_one :vat_clearing_entry, class_name: "JournalEntry", foreign_key: :vat_report_id,
                               inverse_of: :vat_report

  # Marked final: the return has been submitted, and the coded entries of its
  # period are locked (JournalEntry#final_vat_report).
  scope :finalized, -> { where.not(finalized_at: nil) }
  scope :covering, ->(entity_code:, scheme:, date:) {
    joins(report_group: :entity)
      .where(entities: { code: entity_code }, report_groups: { tax_scheme: scheme })
      .where("reports.start_date <= :date AND reports.end_date >= :date", date: date)
  }

  before_destroy :keep_while_final

  def finalized? = finalized_at.present?

  # The return as it stands in the books right now.
  def vat_return_data
    Reports::VatReturn.new(
      entity: report_group.entity, scheme: tax_scheme,
      from:   start_date, to: end_date,
      # From the REPORT, so a rate change or joining the scheme mid-year cannot
      # rewrite a quarter already filed.
      flat_rate_bps: flat_rate_bps,
      prepayment:    prepayment
    ).call
  end

  # The report before this one in the same group, by period: where the flat-rate
  # placeholder and the "no longer flat rate" notice take their figure from.
  def previous_in_group
    scope = Report.where(report_group_id: report_group_id).where("end_date < ?", start_date || Date.current)
    scope = scope.where.not(id: id) if persisted?
    scope.order(end_date: :desc).first
  end

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

  # A prepayment the authority fixed, deducted on this return — Germany's
  # Sondervorauszahlung. Minor units in the column; the form takes the amount,
  # point-only like the field above.
  validates :prepayment, numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                         allow_nil: true

  def prepayment_display
    prepayment && prepayment / 100.0
  end

  def prepayment_display=(value)
    self.prepayment = value.presence && (value.to_f * 100).round
  end
  validate :end_date_after_start_date
  validate :flat_rate_and_prepayment_only_where_the_scheme_has_them
  validate :figures_fixed_while_final

private

  # The form only shows the fields where the scheme has them; this refuses a
  # value sent anyway. A prepayment on a scheme without the box would still be
  # subtracted from the amount to pay.
  def flat_rate_and_prepayment_only_where_the_scheme_has_them
    errors.add(:flat_rate_bps, :present) if flat_rate_bps && !report_group&.flat_rate?
    errors.add(:prepayment, :present) if prepayment &&
                                         !TaxSchemeConfig.prepayment_category(report_group&.tax_scheme)
  end

  # The period is what is locked, and the rate and prepayment are part of the
  # figures that were submitted. The name may still change.
  def figures_fixed_while_final
    return unless finalized_at_in_database.present?
    fixed = %w[start_date end_date flat_rate_bps prepayment report_group_id]
    return if (changed & fixed).empty?
    errors.add(:base, I18n.t("reports.errors.final_is_fixed"))
  end

  # Reopen first: deleting a final report would drop the lock and leave its
  # clearing entry pointing at nothing.
  def keep_while_final
    return unless finalized?
    errors.add(:base, I18n.t("reports.errors.final_cannot_delete"))
    throw :abort
  end

  def end_date_after_start_date
    return unless start_date && end_date

    if end_date <= start_date
      errors.add(:end_date, I18n.t("reports.errors.end_date_after_start"))
    end
  end

end
