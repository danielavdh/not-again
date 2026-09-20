# frozen_string_literal: true

class Entity < ApplicationRecord

  # Years an orphaned entity's bookkeeping is retained before it may be deleted.
  #
  # Flat, not per country, and therefore deliberately longer than some countries
  # require: DE and CH are 10 years (§ 147 AO / § 257 HGB, Art. 958f OR), German
  # vouchers only 8 since 2025, and GB just 5 from the 31 January filing
  # deadline. Over-retention is the safe direction and the purge is
  # sudo-confirmed anyway.
  #
  # Covers the whole entity dataset, books and receipts together — a receipt is a
  # legally retained voucher, not a disposable attachment.
  RETENTION_YEARS = 10

  # Countries, schemes and authorities are not listed here — they are read from
  # the YAML headers in db/tax_categories via TaxSchemeConfig, so adding a
  # country needs no model change.
  def self.valid_country_codes
    TaxSchemeConfig.countries
  end

  # Keyed by scheme rather than listed: every caller wants the group for THIS
  # scheme, never the collection. One per subscribed scheme, created on save.
  def tax_report_groups_by_scheme
    report_groups.where.not(tax_scheme: nil).index_by(&:tax_scheme)
  end

  def self.schemes_by_country
    TaxSchemeConfig.schemes_by_country
  end

  belongs_to :entity_group,
             class_name: 'EntityGroup',
             foreign_key: :entity_group_id,
             optional: true
  has_many :report_groups,
           class_name: 'ReportGroup',
           foreign_key: :entity_id,
           dependent: :destroy
  has_many :admin_entities, 
           class_name: 'AdminEntity', 
           foreign_key: :entity_id, 
           dependent: :destroy
  has_many :admins, through: :admin_entities
  has_many :receipts,
           class_name: "Receipt",
           foreign_key: :entity_id,
           dependent: :destroy
  has_many :entity_group_memberships, dependent: :destroy

  # An entity holds no filing credentials. The taxpayer and the permission
  # belong to a Taxpayer, reached through a tax report group — one person may
  # keep several sets of books, and one set of books may serve several
  # authorities.

  validates :name, presence: true
  validates :code, presence: true, 
                   uniqueness: true, 
                   format: { with: /\A\d{2}\z/, message: "must be 2 digits" }
  validate  :tax_schemes_exist_in_catalogue
  validate  :family_ties_do_not_block_leaving, if: :leaving_a_family?

  after_create  :open_initial_membership_stint
  after_save    :track_group_membership_change, if: :saved_change_to_entity_group_id?

  scope :active, -> { where(active: true) }
  scope :by_code, ->(code) { where(code: code) }
  scope :orphaned, -> { where.not(orphaned_at: nil) }
  scope :with_relationship, -> { where(orphaned_at: nil) }
  scope :due_for_deletion, -> { orphaned.where(deletion_due_on: ..Date.current) }

  # An entity is orphaned when it has no admin links (its last bookkeeper left).
  # It is frozen (no one but sudo can reach it) and a retention clock starts.
  def orphaned?
    orphaned_at.present?
  end

  # Called from AdminEntity after_create/after_destroy, so every link change is
  # covered. update_columns: no validations, no callbacks, no recursion.
  def refresh_orphan_state!
    return if destroyed? || marked_for_destruction?

    if admin_entities.exists?
      # A bookkeeper is (still/again) attached — clear any orphan state.
      update_columns(orphaned_at: nil, deletion_due_on: nil) if orphaned?
    elsif !orphaned?
      # Last bookkeeper just left — start the retention clock.
      now = Time.current
      update_columns(orphaned_at: now,
                     deletion_due_on: now.to_date + RETENTION_YEARS.years)
    end
  end

  # Orphaned AND past its retention deadline: sudo may now confirm deletion.
  def due_for_deletion?
    orphaned? && deletion_due_on.present? && deletion_due_on <= Date.current
  end

  # Codes of every entity in this entity's consolidation group, or just its own
  # if it is ungrouped. Drives the consolidated balance sheet and trial balance.
  def group_codes
    entity_group_id ? entity_group.entities.pluck(:code) : [code]
  end

  # Grouped codes share their group's key ("g<id>"), ungrouped codes key on
  # themselves ("e<code>"). A journal entry stays within a single group iff
  # these keys collapse to one — see JournalEntry. One query, no records loaded.
  def self.group_key_for_codes(codes)
    grouped = where(code: codes).pluck(:code, :entity_group_id).to_h
    codes.index_with { |c| (gid = grouped[c]) ? "g#{gid}" : "e#{c}" }
  end

  # Expands entity codes to their whole consolidation family; ungrouped codes
  # map to themselves. A balance sheet or trial balance only balances at the
  # family level, so selecting any member must pull in the rest.
  def self.family_codes_for(codes)
    group_ids = where(code: codes).where.not(entity_group_id: nil)
                  .distinct.pluck(:entity_group_id)
    return codes.uniq if group_ids.empty?

    (codes + where(entity_group_id: group_ids).pluck(:code)).uniq
  end

  # The archive scope ("g<id>" or this entity's own code) this entity's postings
  # on `date` belong to, read from the membership timeline — so a correction
  # reaching into a period when the entity was in a different family, or on its
  # own, lands in the right archive. Falls back to the current scope when no
  # stint covers the date.
  def scope_key_on(date)
    entity_group_memberships.covering(date).first&.scope_key || Archives::Storage.scope_key_for(self)
  end

  # Which entities' postings belong in the archive for one SCOPE and one
  # CALENDAR YEAR, and for which days. Reads the membership timeline, so it
  # works identically for a family scope and a solo one: { entity_code =>
  # [[from, to], ...] }, each range a stint that entity spent in this scope,
  # clamped to that year.
  #
  # An entity that was in a family for part of the year appears in the family's
  # archive for those days and in its own for the rest — never both.
  def self.scope_windows_for(scope_key:, year:)
    year_start = Date.new(year, 1, 1)
    year_end   = Date.new(year, 12, 31)

    stints =
      if scope_key.start_with?("g")
        EntityGroupMembership.where(entity_group_id: scope_key.delete_prefix("g").to_i)
      else
        EntityGroupMembership.joins(:entity)
                             .where(entities: { code: scope_key }, entity_group_id: nil)
      end

    windows = stints.overlapping(year_start, year_end)
                    .includes(:entity)
                    .group_by { |m| m.entity.code }
                    .transform_values do |rows|
                      rows.map { |m|
                        [ [ m.starts_on, year_start ].max,
                          m.ends_on ? [ m.ends_on, year_end ].min : year_end ]
                      }.sort
                    end

    # A solo scope with no timeline row (fixtures, or an entity that predates
    # the timeline and was never grouped) is unrestricted for the year — it was
    # always its own scope.
    if windows.empty? && !scope_key.start_with?("g") && exists?(code: scope_key)
      windows[scope_key] = [ [ year_start, year_end ] ]
    end
    windows
  end

  # Ids of journal entries where this entity's accounts appear ALONGSIDE a
  # sibling's — a plain entry mixing family accounts directly, with no bridge. A
  # link to some other, unrelated entity is the gift/equity-bridge mechanism, a
  # separate feature entirely, and does not block leaving: only entanglement
  # with THIS family does.
  def cross_family_journal_entry_ids(sibling_codes)
    return [] if sibling_codes.empty?

    mine = Posting.joins(:account)
                       .where("SUBSTRING(accounts.code, 2, 2) = ?", code)
                       .distinct.pluck(:journal_entry_id)
    return [] if mine.empty?

    Posting.joins(:account)
                .where(journal_entry_id: mine)
                .where("SUBSTRING(accounts.code, 2, 2) IN (?)", sibling_codes)
                .distinct.pluck(:journal_entry_id)
  end

  # Every scheme in the catalogue, from any country. An entity has no country of
  # its own — the scheme names one, so a business filing in two places simply
  # carries two schemes.
  def available_tax_schemes
    TaxSchemeConfig.all_schemes
  end

  # The dashboard's tax row: ONE next step per scheme, and nothing that leads
  # nowhere.
  #
  # no taxpayer        → neither; the setup button is the whole row
  # taxpayer, no token → connect
  # connected          → submit
  #
  # Connect is keyed by AUTHORITY, not by scheme: one login covers every scheme
  # behind it, so two GB schemes would otherwise grow two identical buttons.
  #
  # Reads report_groups and their taxpayers from memory; the dashboard preloads
  # both, so this adds no queries per entity.
  def filing_offers
    offers = Array(tax_schemes).filter_map do |scheme|
      connector = TaxSchemeConfig.connector_for(scheme)
      klass     = Filing::Base.connector_class(connector)
      next unless klass

      taxpayer = report_groups.detect { |g| g.tax_scheme == scheme }&.taxpayer
      { scheme: scheme, connector: connector, authority_key: klass.authority_key,
        authority: TaxSchemeConfig.authority_for_connector(connector),
        taxpayer: taxpayer }
    end

    {
      # The scheme AND what is sent for it. It used to hand back a bare slug
      # and leave the dashboard to ask a config object what it was called.
      submit:  offers.select { |o| o[:taxpayer]&.connected? }
                     .map { |o| { scheme: o[:scheme],
                                  name: TaxSchemeConfig.submission_name_for(o[:scheme]) } },
      connect: offers.reject { |o| o[:taxpayer].nil? || o[:taxpayer].connected? }
                     .uniq { |o| o[:authority_key] }
    }
  end

  private

    def tax_schemes_exist_in_catalogue
      return if tax_schemes.blank?
      unknown = Array(tax_schemes) - available_tax_schemes
      errors.add(:tax_schemes, "unknown: #{unknown.join(', ')}") if unknown.any?
    end

    # Joining a family from ungrouped is always allowed — only LEAVING one (to
    # none, or sudo moving straight to a different family) needs checking,
    # against whichever group is being left.
    def leaving_a_family?
      persisted? && entity_group_id_changed? && entity_group_id_was.present?
    end

    # Three ways this entity can be tied into the family it is leaving: real
    # cross-entity journal entries with a sibling, its own report group holding
    # a sibling's account, or a sibling's report group holding one of its own.
    # Any of these ties survives the entity leaving — the archive side does not,
    # which is why this checks only these three and not "any archive already
    # exists".
    def family_ties_do_not_block_leaving
      sibling_codes = self.class.where(entity_group_id: entity_group_id_was).where.not(id: id).pluck(:code)
      return if sibling_codes.empty?

      # :base, not :entity_group_id — these are already complete sentences, and
      # full_messages prepends the humanized attribute name to anything added
      # under a real attribute.
      if cross_family_journal_entry_ids(sibling_codes).any?
        errors.add(:base, I18n.t("entities.errors.family_leave.shared_journal_entries"))
      end
      if report_groups.joins(:accounts).merge(Account.for_entity_codes(sibling_codes)).exists?
        errors.add(:base, I18n.t("entities.errors.family_leave.own_report_group"))
      end
      if ReportGroup.where(entity_id: self.class.where(code: sibling_codes).select(:id))
                    .joins(:accounts).merge(Account.for_entity_codes([code])).exists?
        errors.add(:base, I18n.t("entities.errors.family_leave.sibling_report_group"))
      end
    end

    # Every entity's timeline starts the day it is created — a solo stint
    # unless it was created straight into a family.
    def open_initial_membership_stint
      return if entity_group_memberships.exists?
      entity_group_memberships.create!(
        entity_group_id: entity_group_id,
        starts_on: created_at.to_date
      )
    end

    # Keeps the timeline gap-free when entity_group_id changes: close the open
    # stint at yesterday, open the new one today, solo when the new value is
    # nil. Covers join, leave and a sudo direct move uniformly.
    #
    # Then: a family needs two members, so if this move drops the old group to
    # one, that lone member is on its own again.
    def track_group_membership_change
      old_group_id, new_group_id = saved_change_to_entity_group_id
      today = Date.current

      open_row = entity_group_memberships.open.first
      if open_row && open_row.starts_on < today
        open_row.update_columns(ends_on: today - 1)
      elsif open_row
        open_row.destroy # a same-day flip: the stint never really existed
      end
      entity_group_memberships.create!(entity_group_id: new_group_id, starts_on: today)

      collapse_orphaned_family(old_group_id) if old_group_id
    end

    # A one-member family is just an entity: when a departure leaves exactly one
    # member behind, that member reverts to solo — its own update fires this
    # same callback, harmlessly. The emptied or collapsed group's archives are
    # flushed to permanent storage in the background, since no sibling close
    # will ever trigger them again.
    def collapse_orphaned_family(group_id)
      remaining = Entity.where(entity_group_id: group_id).to_a
      return if remaining.size >= 2

      remaining.first&.update!(entity_group: nil)
      Archives::FlushJob.perform_later("g#{group_id}")
    end
end
