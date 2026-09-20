require 'bcrypt'
class Admin < ApplicationRecord
    has_secure_password
    has_many :sessions, dependent: :destroy
    # Taxpayers this admin CREATED — whose record it is to edit and delete,
    # never who may file. That is #usable_taxpayers.
    #
    # No `dependent:` deliberately: it would run FIRST, as a before_destroy
    # added at declaration, and clear admin_id before
    # #release_or_destroy_taxpayers could tell which taxpayers are still in use.
    # Without it the foreign key blocks a raw #delete, which is the net we want.
  has_many :taxpayers, class_name: "Taxpayer"

  has_many :admin_entities, class_name: "AdminEntity", dependent: :destroy
    has_many :entities, through: :admin_entities, source: :entity
    # this is only relevant for upload_only admins, so they can delete their
    # unlinked receipts:
    has_many :uploaded_receipts, class_name: "Receipt", foreign_key: :uploaded_by_id, dependent: :nullify
    # Same reasoning as uploaded_receipts: the record of an attempt outlives the
    # account it was made against. username_attempted keeps the name.
    has_many :sign_in_events, dependent: :nullify
    # Bump this when the terms text in app/views/help/_terms_text_* changes
    # materially: every admin, new or already in the database, is gated again
    # until terms_agreed_version matches, with no data migration.
    TERMS_VERSION = "2026-09-03"

    # How long an unclaimed draft lives, and so how long its verification link
    # stays valid. Admins::DraftSweepJob enforces the first; generates_token_for
    # below the second. One fact, so the two cannot drift apart.
    UNCLAIMED_LIFETIME = 1.month

    # Plain columns rather than updated_at: that is clobbered by every unrelated
    # save, the admin's own preferences form included, so the date needs its own
    # column.
    def agreed_to_current_terms?
      terms_agreed_version == TERMS_VERSION
    end

    def verified?
      verified_at.present?
    end

    def verify!
      update(verified_at: Time.current)
    end

    # A coadmin created for a brand-new email by another full-access admin, who
    # chose the username and password and so still holds the keys until the
    # account is claimed. draft? ends at first successful login, forced through
    # confirming the email AND setting a real password in one sequence
    # (GatesController#claim_show/claim_update) — never earlier, never
    # separately. Until then that admin may delete the account outright.
    #
    # An admin sudo creates directly is never a draft.
    #
    # Never demo, structurally rather than by setting claimed_at at creation:
    # that would need every creation path to remember, and one already did not.
    # Demo has no email to confirm, so draft cannot mean anything for it.
    def draft?
      !demo? && claimed_at.nil?
    end

    def claim!
      update!(claimed_at: Time.current)
    end


    generates_token_for :password_reset, expires_in: 15.minutes do
      password_digest.last(10)
    end
    # email_address in the block, not an id or a digest: generates_token_for
    # compares this value at verification time, so an old link stops working the
    # instant the address is edited, rather than needing a separate revocation
    # step.
    # As long as the draft it unlocks (Admins::DraftSweepJob). At 24 hours the
    # link died on day two while the account it belonged to lived another
    # month, so a stale inbox link was the ordinary case rather than a mistake.
    generates_token_for :email_verification, expires_in: UNCLAIMED_LIFETIME do
      email_address
    end
    validates :username, presence: true, uniqueness: true
    # allow_nil, so an update that does not touch the password still saves.
    validates :password, length: { minimum: 8 }, allow_nil: true
    validates :email_address, uniqueness: true, allow_blank: true
    # Demo is the one exception: no real password, no OTP, and nothing here is
    # reachable except through the /demo button.
    validates :email_address, presence: true, unless: :demo?
    normalizes :email_address, with: ->(e) { e.strip.downcase }
    # Blank = follow the UI language; anything else must be a known format slug.
    validates :preferred_number_format,
              inclusion: { in: NumberFormat::FORMATS.keys }, allow_blank: true
    # The token for the OLD address stops working on its own, but verified_at
    # would otherwise keep claiming the NEW address was confirmed when nothing
    # has confirmed it.
    before_save :clear_verified_at_if_email_changed
    before_create :add_last_seen
    before_destroy :ensure_an_admin_remains
    before_destroy :ensure_an_owner_remains
    validate       :ensure_an_owner_remains_on_update, on: :update
    # After ensure_an_admin_remains, so an aborted destroy takes no taxpayer
    # with it.
    before_destroy :release_or_destroy_taxpayers

    def self.otp_required?
      Rails.env.production?
    end

    # The accounts that never meet the second factor, and therefore the only
    # ones whose session can be resumed indefinitely from a permanent cookie —
    # which is also what makes them the only sessions worth sweeping for going
    # quiet.
    def otp_exempt?
      demo? || upload_receipts_only?
    end

    # The SQL twin of #upload_receipts_only?, which reads the links in Ruby and
    # so cannot be used to select rows. Two subqueries, nothing loaded: has at
    # least one upload_receipts link, and no link that is anything else.
    scope :upload_receipts_only, -> {
      where(id: AdminEntity.where(access_level: :upload_receipts).select(:admin_id))
        .where.not(id: AdminEntity.where.not(access_level: :upload_receipts).select(:admin_id))
    }

    def sudo?
      sudo
    end

    # May this admin be shown a link that OPENS an entry form? Not the same
    # question as "may they save it", which is answered per entity by
    # require_writable_account when the form is submitted.
    #
    # Deliberately NOT used for buttons that ACT — a delete button or a year-end
    # close shown to someone who will be refused is worse than no button.
    def may_open_entry_forms?
      sudo? || full_access? || demo?
    end

    def full_access_pro?
      # Two demo accounts, one with the tick and one without, which is what lets
      # the demo page offer the plain version and the pro version as separate
      # doors.
      return show_journal_entries? if demo?

      sudo? || (full_access? && (!self.class.otp_required? || otp_enabled?) && show_journal_entries?)
    end    

    def add_last_seen
      self.last_seen = Time.now
    end

    # Owners are immune from every other owner, but may always manage
    # themselves. A full-access admin manages another only while that admin is
    # not full_access anywhere (once they are, they are a peer, not a coadmin)
    # and the two share an entity this admin holds full_access on — checked live
    # against current links, never against a fixed record of who invited whom.
    def can_manage?(other_admin)
      return false if other_admin.sudo? && other_admin != self
      return false if other_admin == self && !sudo?
      return true if sudo?
      full_access? && !other_admin.full_access? && shares_full_access_entity_with?(other_admin)
    end

    # The one check both #can_manage? (which adds "and they are not
    # full_access") and the admins/show view gate are built from, so the two
    # cannot drift into checking different things.
    def shares_full_access_entity_with?(other_admin)
      (admin_entities.with_full_access.pluck(:entity_id) &
        other_admin.admin_entities.pluck(:entity_id)).any?
    end

    # The only slice of another admin's access this one has any business
    # reading: their links on entities I hold full_access on. Never read
    # other.admin_entities directly for the authorised-access table — that leaks
    # entity codes the viewer has no relationship with.
    #
    # Batched rather than per-admin: the table renders one row per (coadmin,
    # shared entity), so asking per coadmin is an N+1 on the page that exists to
    # list them. { admin_id => [AdminEntity, ...] }, entities eager-loaded and
    # ordered as the table renders them.
    def shared_admin_entities_by_admin(others)
      AdminEntity.where(admin_id: others)
                 .where(entity_id: admin_entities.with_full_access.select(:entity_id))
                 .includes(:entity)
                 .references(:entity)
                 .order("entities.code")
                 .group_by(&:admin_id)
    end

    # Everyone linked to an entity I hold full_access on, excluding myself — the
    # row set for the authorised-access table.
    #
    # Deliberately does NOT exclude an admin who has since gained full_access
    # elsewhere: they must stay VISIBLE to their old admins and only become un-
    # editable, which can_manage? decides per row in the view. Excluding them
    # made a promoted coadmin vanish entirely, including from the page of the
    # admin whose own entity they still held a link to.
    def managed_admins
      return Admin.none unless full_access?

      entity_ids = admin_entities.with_full_access.select(:entity_id)
      Admin.joins(:admin_entities)
           .where(admin_entities: { entity_id: entity_ids })
           .where.not(id: id)
           .distinct
    end

    # --- Entity-Based Access Control ---
    def can_access_accounts?
      has_entities? || sudo?
    end
    # All entity codes this admin has access to
    def entity_codes
      @entity_codes ||= entities.pluck(:code)
    end

    # Memoised, and current_admin is one object for the life of a request, so
    # this is request-scoped in practice. Anything that changes an admin's links
    # and then reads them back off the SAME object must call
    # reset_access_cache!.
    def has_entities?
      return @has_entities unless @has_entities.nil?
      @has_entities = entities.any?
    end

    # The links themselves, loaded once. Bounded by the number of entities one
    # admin holds, so this is a handful of rows, not a collection.
    def access_links
      @access_links ||= admin_entities.to_a
    end

    def reset_access_cache!
      @has_entities = nil
      @entity_codes = nil
      @access_links = nil
      @full_access_entity_ids = nil
    end
    # Entity codes where this admin has full bookkeeping access
    def full_access_entity_codes
      admin_entities.with_full_access.joins(:entity).pluck('entities.code')
    end
    def can_access_account?(account)
      return false unless can_access_accounts?
      accessible_accounts.exists?(account.id)
    end
    def owns_account?(account)
      # Owns = account belongs to one of admin's directly assigned entities
      return false unless has_entities?
      entity_codes.include?(account.entity_code)
    end


    def accessible_entity_ids
      if sudo?
        Entity.pluck(:id)
      else
        admin_entities.pluck(:entity_id)
      end
    end
    def accessible_accounts
      if sudo?
        Account.all
      elsif has_entities?
        Account.for_entity_codes(entity_codes)
      else
        Account.none
      end
    end
    def accessible_entities
      if sudo?
        Entity.all
      elsif has_entities?
        Entity.where(id: accessible_entity_ids)
      else
        Entity.none
      end
    end

    # Only with FULL access to every current member — you do not rearrange a
    # family that partly belongs to someone else. Sudo always may.
    def manages_family?(group)
      return false if group.nil?
      return true  if sudo?
      (group.entity_ids - writable_entity_ids).empty?
    end

    # Sudo may use any; a full-access admin only families whose members they
    # entirely hold with full access — never grouping with someone else's
    # entity, and never on a read-only link. New families are typed straight
    # into the TomSelect.
    def assignable_entity_groups
      return EntityGroup.order(:name) if sudo?

      EntityGroup
        .where.not(id: Entity.where.not(entity_group_id: nil)
                                  .where.not(code: full_access_entity_codes)
                                  .select(:entity_group_id))
        .order(:name)
    end
    def accessible_journal_entries
      JournalEntry.where(id:
        Posting.where(account_id: accessible_accounts.select(:id))
                    .select(:journal_entry_id)
      )
    end
    def accessible_postings
      Posting.where(account_id: accessible_accounts.select(:id))
    end
    def accessible_receipts
      Receipt.where(entity_id: accessible_entity_ids)
    end
    def accessible_report_groups
      ReportGroup.where(entity_id: accessible_entity_ids)
    end
    def accessible_reports
      Report.where(report_group_id: accessible_report_groups.select(:id))
    end

    # Write scope, not read scope. The read scope above spans every entity the
    # admin is linked to at any access level; this one does not, because levels
    # are granted per entity — an admin who keeps the books for 01 and merely
    # reads 07 must not be able to post into 07. Sudo is never blocked by an
    # access level.

    # Memoised for the same reason as access_links: AdminEntity#removable_by?
    # asks it once per row of the authorised-access table.
    def full_access_entity_ids
      @full_access_entity_ids ||= admin_entities.with_full_access.pluck(:entity_id)
    end

    def writable_entity_ids
      sudo? ? Entity.pluck(:id) : full_access_entity_ids
    end

    def writable_entity_codes
      if sudo?
        Entity.pluck(:code)
      else
        full_access_entity_codes
      end
    end

    def writable_accounts
      return Account.all if sudo?

      codes = writable_entity_codes
      codes.any? ? Account.for_entity_codes(codes) : Account.none
    end

    def writable_journal_entries
      JournalEntry.where(id:
        Posting.where(account_id: writable_accounts.select(:id))
                    .select(:journal_entry_id)
      )
    end

    def writable_postings
      Posting.where(account_id: writable_accounts.select(:id))
    end

    def writable_report_groups
      ReportGroup.where(entity_id: writable_entity_ids)
    end

    # Taxpayers this admin may USE: the ones they created, plus any already
    # filing for an entity they can write to — so a bookkeeper and their
    # assistant share one grant instead of asking the client to authorise twice,
    # and the assistant can re-authorise when the token expires.
    #
    # Writable, not accessible: a read_only admin has no business filing.
    def usable_taxpayers
      Taxpayer.where(admin_id: id)
                   .or(Taxpayer.where(
                         id: writable_report_groups.select(:taxpayer_id)))
    end

    def writable_reports
      Report.where(report_group_id: writable_report_groups.select(:id))
    end

    # Receipts follow receipt access, not bookkeeping access: an upload_receipts
    # link is enough, a read_only one never is.
    def writable_receipts
      Receipt.where(entity_id: upload_entity_ids)
    end

    # May this admin change things in this entity at all?
    def can_write_entity_code?(code)
      return false if code.blank?
      writable_entity_codes.include?(code)
    end

    # A solo entity's archive is that entity's own ledger, so any link at any
    # level is enough. A family's archive is the WHOLE family's ledger, posting-
    # level, in one file (Archives::BooksCsv) — access to one member is not
    # access to the rest, so that requires write access to every member.
    def can_use_archive?(scope_key)
      return true if sudo?

      codes = Archives::Storage.member_codes_for(scope_key)
      return entity_codes.include?(codes.first) if codes.size <= 1

      codes.all? { |code| writable_entity_codes.include?(code) }
    end

    ##########################################
    # Admin entities access/permissions levels
    def upload_entity_ids
      if sudo?
        Entity.pluck(:id)
      else
        admin_entities.with_receipt_access.pluck(:entity_id)
      end
    end
    def upload_receipts_only?
      access_links.any? && access_links.all?(&:upload_receipts?)
    end
    def read_only?
      access_links.any? && access_links.all?(&:read_only?)
    end
    def full_access?
      access_links.any?(&:full_access?)
    end
    # A set, not a single answer: one admin can be full_access on one business
    # and read_only on another. The domain fact only — naming each level for a
    # reader is the view's job.
    def access_levels
      access_links.map(&:access_level).uniq
    end
    def can_invite_for_entity?(entity)
      admin_entities.exists?(entity_id: entity.id, access_level: :full_access)
    end
    def manageable_entities
      entities.where(id: admin_entities.with_full_access.select(:entity_id))
    end 

    # Primary entity code (for default currency, account creation prefix)
    # Falls back to entity_code column, then first assigned entity
    def primary_entity_code
      entity_code.presence || entities.first&.code
    end

    # For creating new accounts - must use one of their entity codes
    def account_code_prefix
      primary_entity_code
    end

    # Has a second factor actually been set up? otp_enabled is a flag; the
    # secret
    # is what the check needs, so this is the honest question.
    def otp_configured?
      otp_secret.present?
    end

    # Every owner, not whichever one has the lowest id: on an installation with
    # two, the second must still hear that a backup stopped or a rate fetch
    # died. Falls back to CONTACT_EMAIL, and never a hardcoded address, so a
    # self-hoster's alerts do not reach whoever wrote this file.
    def self.owner_addresses
      where(sudo: true).where.not(email_address: [ nil, "" ]).order(:id).pluck(:email_address).presence ||
        [ CONTACT_EMAIL ]
    end

    def disable_otp!
      update!(otp_enabled: false, otp_secret: nil)
    end

private unless 'test' == Rails.env

    def clear_verified_at_if_email_changed
      self.verified_at = nil if email_address_changed? && persisted?
    end

    def ensure_an_admin_remains
      throw(:abort) if Admin.count <= 1
    end

    # An installation with no owner cannot be administered at all — only sudo
    # passes ensure_full_access without an entity link — so both routes out are
    # closed: deleting the last owner, and un-ticking their own box.
    #
    # sudo_in_database, NOT sudo?: sudo? reads the in-memory attribute, and a
    # failed demotion leaves it false while the database still says true, so
    # update(sudo: false) followed by destroy on that same object destroyed the
    # last owner.
    def ensure_an_owner_remains
      throw(:abort) if sudo_in_database && Admin.where(sudo: true).count <= 1
    end

    def ensure_an_owner_remains_on_update
      return unless sudo_change == [ true, false ]
      return if Admin.where(sudo: true).where.not(id: id).exists?

      errors.add(:sudo, "cannot be taken from the last owner — make someone else an owner first")
    end

    # A taxpayer nobody else is filing with goes with them; one still attached
    # to a report group loses its creator and lives on, usable through its
    # entities. destroy_all on the unused few because they need callbacks and
    # encrypted tokens, then a single UPDATE for the rest.
    def release_or_destroy_taxpayers
      in_use = ReportGroup.where.not(taxpayer_id: nil).select(:taxpayer_id)
      taxpayers.where.not(id: in_use).destroy_all
      taxpayers.update_all(admin_id: nil)
    end
end
