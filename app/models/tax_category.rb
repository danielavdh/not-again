# frozen_string_literal: true

class TaxCategory < ApplicationRecord

  # What a figure IS, and there are exactly three answers: it adds to income, it
  # subtracts as expenditure, or it appears on the form and does neither. The
  # third is not a dustbin — tax deducted at source is the live case, money a
  # payer already handed to the authority on your behalf, which must be reported
  # and would falsify the return counted as either of the others.
  #
  # The APP's vocabulary, deliberately, and the one thing about a tax category
  # that is not in the form's own language. The form's wording for the box is
  # `label`, which is never translated. Making section free text so it could
  # carry the German word cost a silent zero in every total — see
  # TaxCategoryLoader#check_section!.
  INCOME   = "income"
  EXPENSES = "expenses"
  OTHER    = "other"
  VALID_SECTIONS = [ INCOME, EXPENSES, OTHER ].freeze

  validates :country_code, presence: true, format: { with: /\A[a-z]{2}\z/ }
  validates :scheme,       presence: true, format: { with: /\A[a-z][a-z0-9_]*\z/ }
  validates :tax_year,     presence: true, numericality: { only_integer: true, greater_than: 2000 }
  validates :key,          presence: true, format: { with: /\A[a-z][a-z0-9_]*\z/ }
  validates :key,          uniqueness: { scope: [:country_code, :scheme, :tax_year] }
  validates :section, inclusion: { in: VALID_SECTIONS }, allow_nil: true

  scope :for_country, ->(cc)     { where(country_code: cc.to_s.downcase) }
  scope :for_scheme,  ->(s)      { where(scheme: s.to_s) }
  scope :for_year,    ->(y)      { where(tax_year: y.to_i) }
  scope :ordered,     ->         { order(:section, :position, :key) }

  # Finds the catalogue row for a given year, or the newest prior year that
  # exists, so contributors can skip years where the rules did not change.
  # Request 2028 with 2026 and 2029 present → 2026.
  #
  # TODO: `key` here is the account's CURRENT tax_category_key, not whatever it
  # carried when the period being reported was current. Re-tag an account later
  # and this resolves a key against a year that never had it, so the figure
  # silently drops out of an old, already-filed report. Needs a dated
  # account↔category assignment, like EntityGroupMembership, before old reports
  # are actually stable.
  def self.resolve(country_code:, scheme:, year:, key:)
    return nil if [country_code, scheme, year, key].any?(&:blank?)
    for_country(country_code)
      .for_scheme(scheme)
      .where(key: key)
      .where("tax_year <= ?", year.to_i)
      .order(tax_year: :desc)
      .first
  end

  # Which tax year a DATE belongs to. ONE rule for every country: a tax year is
  # named by the year it ENDS in, and the day it ends on is declared per country
  # in the header of its tax category files (tax_year_ends: "04-05"), defaulting
  # to 31 December.
  #
  # That default is not a special case — a calendar year genuinely is a year
  # ending 31 December — so the same arithmetic gives 2028 for a German date in
  # 2028 and 2029 for a British date in July 2028.
  def self.tax_year_for(country_code:, date:)
    return nil if date.blank?

    ends_on = year_end_in(country_code, date.year)
    return date.year unless ends_on

    date <= ends_on ? date.year : date.year + 1
  end

  # The country's tax year end, landed in a given calendar year. Nil rather than
  # a guess if the declared value is not a real date: 31 February is a typo, and
  # silently sliding it to 28 would misfile a whole year of figures.
  def self.year_end_in(country_code, year)
    month, day = TaxSchemeConfig.tax_year_ends(country_code).to_s.split("-", 2)
    Date.new(year, month.to_i, day.to_i)
  rescue ArgumentError, TypeError
    Rails.logger.error("TaxCategory: #{country_code} declares an impossible tax_year_ends; " \
                       "falling back to the calendar year")
    nil
  end
  private_class_method :year_end_in

  # The catalogue AS IT STOOD for a period, keyed by category key — so a 2026
  # return is built from 2026's boxes even once 2027 exists. Without a year the
  # result is non-deterministic: Postgres promises no order without ORDER BY, so
  # two loaded years would keep whichever row came back last per key.
  #
  # The effective year is taken for the SCHEME, not per key: a key dropped in
  # 2027 is genuinely absent when reporting 2027, because the box no longer
  # exists. Resolving each key on its own would resurrect a retired box from an
  # older year.
  def self.for_period(scheme:, keys:, year:)
    keys = Array(keys).compact.uniq
    return {} if scheme.blank? || keys.empty? || year.blank?

    effective = where(scheme: scheme).where("tax_year <= ?", year.to_i).maximum(:tax_year)
    return {} unless effective

    where(scheme: scheme, tax_year: effective, key: keys).index_by(&:key)
  end

  # NOT translated, deliberately. A tax category is a box on a particular
  # country's form, and that box has one name: the one printed on the form. A
  # German Vermietung line is never "service charges", whatever language the app
  # is read in — translating it would invite someone to look for a box that does
  # not exist.
  #
  # The fallback is the key, whose slugs are already native — mieteinnahmen,
  # nettoerloese, sales_income — so a catalogue contributed without labels still
  # reads in its own language rather than in English.
  def label(_locale = nil)
    self[:label].presence || key.to_s.tr("_", " ").capitalize
  end

  # Where a SUBMISSION puts this figure, which is not always what the figure IS.
  # Tax deducted at source forces the two apart: HMRC files it inside the income
  # object of both GB schemes, but it is not income — it is money a payer
  # already handed to HMRC on your behalf, and counting it as turnover would
  # overstate every report that touches the account.
  #
  # So `section` says what the figure is, and drives the totals; this says where
  # the payload puts it. Defaults to section.
  def payload_section
    self[:api_section].presence || section
  end

  # What you quote to find this figure on the paper form: "01" against Anlage V,
  # "15" against SA103F, "959b:2.1" against the Obligationenrecht. Shown next to
  # the label and used as the Reference column of the tax CSV.
  def reference
    export_column.presence
  end

  # "52 — Umgelegte Kosten". The reference first because that is what you match
  # against the form, and because it sorts the dropdown the way the form reads.
  def display_name
    reference ? "#{reference} — #{label}" : label
  end

  # Options for a category select, grouped by section, for every scheme given.
  # One builder, because there were three — dashboard, account form, tax report
  # page — and they had already drifted apart once. Each option is a triple, so
  # the note travels to the browser as a data attribute on the <option>.
  def self.grouped_options(schemes)
    schemes = Array(schemes)
    return [] if schemes.empty?

    # The catalogue's newest year. Contributors skip years in which nothing
    # changed, so this is the year in force, not necessarily the current one.
    latest = where(scheme: schemes).maximum(:tax_year)
    return [] unless latest

    # Only worth naming the scheme when there is more than one to confuse.
    label_scheme = schemes.size > 1

    where(scheme: schemes, tax_year: latest)
      .order(:section, :position, :key)
      .group_by { |row| row.section || "other" }
      .map { |section, rows|
        [ I18n.t("tax.section.#{section}", default: section.humanize),
          rows.map { |row|
            prefix = label_scheme ? "[#{TaxSchemeConfig.scheme_label(row.scheme)}] " : ""
            [ "#{prefix}#{row.display_name}",
              "#{row.scheme}::#{row.key}",
              { data: { note: row.notes.presence } } ]
          } ]
      }
  end
end