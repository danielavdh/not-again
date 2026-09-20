# frozen_string_literal: true

class ReportGroup < ApplicationRecord

  belongs_to :entity, class_name: 'Entity', foreign_key: :entity_id
  has_many :report_group_accounts, 
           class_name: 'ReportGroupAccount', 
           foreign_key: :report_group_id, 
           dependent: :destroy
  has_many :accounts, through: :report_group_accounts
  has_many :reports,
           -> { order(:start_date, :end_date) },
           class_name: 'Report',
           foreign_key: :report_group_id,
           dependent: :destroy

  # Whose figures these are, at the authority this scheme files with. Chosen,
  # not derived: a taxpayer with several sets of books picks the same taxpayer
  # for each, which is what gives them one login and one copy of their number.
  # Nil until someone actually files — tagging, reports and exports need no
  # taxpayer at all.
  belongs_to :taxpayer,
             class_name: 'Taxpayer',
             foreign_key: :taxpayer_id,
             optional: true

  scope :ordered, -> { order(:position) }
  scope :templates, -> { where(is_template: true) }
  
  validates :name, presence: true
  validates :tax_scheme, inclusion: { in: ->(_g) { TaxSchemeConfig.all_schemes }, allow_nil: true }
  validate  :one_taxpayer_per_authority, if: :taxpayer_id?
  validate  :one_group_per_business, if: -> { taxpayer_id? && business_id.present? }

  scope :tax_reports, -> { where.not(tax_scheme: nil) }
  scope :custom,      -> { where(tax_scheme: nil) }

  # A TAX report's accounts are every account tagged with this scheme, rather
  # than a set someone curated. A custom group is a chosen list; a tax group is
  # a saved query, so nothing is stored that could go stale.
  def tax_report?
    tax_scheme.present?
  end

  # Which authority this group's scheme files with — "hmrc". Nil for a custom
  # group, or a scheme that stops at tagging and export.
  def authority_key
    return nil unless tax_report?
    Filing::Base.connector_class(TaxSchemeConfig.connector_for(tax_scheme))&.authority_key
  end

  # Ready to file: we know whose figures these are, which of that taxpayer's
  # businesses they are, and we still hold permission. All three, or the
  # submission has nowhere to go.
  def filable?
    tax_report? && business_id.present? && !!taxpayer&.connected?
  end

  # Never translated, and declared rather than derived: "GB-self-employment",
  # "DE-EÜR", "CH-Selbst" — capitalisation follows each scheme's own language.
  def display_name
    tax_report? ? (TaxSchemeConfig.report_name(tax_scheme) || name) : name
  end

  # The other two names this group's scheme has. display_name above names the
  # REPORT ("GB-property"); these name the form you tag against ("UK Property
  # (SA105)") and what is actually transmitted ("MTD property").
  #
  # Here rather than looked up in a template: the group knows its scheme, so
  # nothing else should have to ask a config object on its behalf.
  def scheme_label
    TaxSchemeConfig.scheme_label(tax_scheme) if tax_report?
  end

  def submission_name
    TaxSchemeConfig.submission_name_for(tax_scheme) if tax_report?
  end

  # A tax report group belongs to its scheme while the entity is subscribed.
  # Once it unsubscribes the group is left standing — the reports under it are
  # the admin's to keep or discard — but it may then be removed, provided
  # nothing is under it.
  def deletable?
    return reports.empty? unless tax_report?
    reports.empty? && !Array(entity&.tax_schemes).include?(tax_scheme)
  end

  # A tax report totals into the currency its scheme files in; a custom report
  # lets the user pick one.
  def display_currency
    TaxSchemeConfig.currency_for(tax_scheme) if tax_report?
  end

  def accounts_scope
    return accounts unless tax_report?
    Account.active.leaf_accounts
                .where(account_type: [ :income, :expense ], tax_scheme: tax_scheme)
                .for_entity_codes([ entity.code ])
                .order(:code)
  end

  # The accounts a tax REPORT or a filing for a given window is about: the
  # scheme's active accounts, PLUS any inactive one that still has posted
  # activity in the window. A tax-relevant figure belongs on the return whether
  # or not the account was retired since, and leaving it out understates what is
  # filed.
  #
  # accounts_scope (active only) stays the answer for "which accounts can be
  # assigned to this scheme".
  def accounts_for_period(from:, to:)
    return accounts_scope unless tax_report?

    tagged = Account.leaf_accounts
                 .where(account_type: [ :income, :expense ], tax_scheme: tax_scheme)
                 .for_entity_codes([ entity.code ])

    ids  = tagged.where(active: true).ids
    ids += tagged.where(active: false)
                 .where(id: Posting.joins(:journal_entry)
                   .where(journal_entries: { posted: true, entry_date: from..to })
                   .where("journal_entries.closing_entry IS NOT TRUE")
                   .select(:account_id))
                 .ids

    Account.where(id: ids).order(:code)
  end

  # Custom groups order by the position on the join row. A tax group has no join
  # rows, so it falls back to code order — the filed report's category order
  # comes from the scheme's own catalogue (TaxCategory#position, read from the
  # YAML), not from anything stored on the account.
  def account_ids_ordered
    return accounts_scope.pluck(:id) if tax_report?
    report_group_accounts.order(:position).pluck(:account_id)
  end

  # An entity files to one authority as ONE taxpayer. Two people's books in one
  # entity would file under one number with no error anywhere, because accounts
  # carry no taxpayer and nothing downstream can catch it.
  #
  # A backstop only: the tax setup page has one taxpayer picker per authority
  # that writes to every group behind it, so this cannot be reached through the
  # UI. It guards the console.
  def one_taxpayer_per_authority
    key = authority_key
    return if key.nil?

    siblings = TaxSchemeConfig.all_schemes.select { |s|
      Filing::Base.connector_class(TaxSchemeConfig.connector_for(s))&.authority_key == key
    }
    # One EXISTS query, nothing loaded: does this entity already file to this
    # authority as someone else?
    clash = self.class.where(entity_id: entity_id, tax_scheme: siblings)
                      .where.not(id: id)
                      .where.not(taxpayer_id: [ nil, taxpayer_id ])
                      .exists?
    errors.add(:taxpayer_id, I18n.t("filing.register.one_per_authority")) if clash
  end

  # One business, one set of books. Two groups filing the same business would
  # take turns overwriting each other at the authority — each update replaces
  # the last one for that business, so it keeps whichever went last and the
  # other trade is never filed at all. Nothing errors at either end, and both
  # archived copies look right on their own.
  #
  # Per TAXPAYER, not globally: the authority issues these per taxpayer, and two
  # accountants may each hold a taxpayer row for the same client. Those are
  # separate arrangements, and the same identifier under both is not a clash.
  #
  # A backstop only — the tax setup page leaves claimed businesses out of the
  # dropdown, so this guards the console and a stale form.
  def one_group_per_business
    # One EXISTS query, nothing loaded.
    clash = self.class.where(taxpayer_id: taxpayer_id, business_id: business_id)
                      .where.not(id: id)
                      .exists?
    errors.add(:business_id, I18n.t("filing.register.business_taken")) if clash
  end

  # NEW: Update account selection with positions
  def update_accounts(account_ids_with_positions)
    transaction do
      report_group_accounts.destroy_all
      account_ids_with_positions.each do |account_id, position|
        report_group_accounts.create!(
          account_id: account_id,
          position: position
        )
      end
    end
  end

end