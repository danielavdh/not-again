# frozen_string_literal: true

class AdminEntity < ApplicationRecord

  belongs_to :admin
  belongs_to :entity, class_name: "Entity", foreign_key: :entity_id

  enum :access_level, { full_access: 0, upload_receipts: 1, read_only: 2 }

  validates :admin_id, uniqueness: { scope: :entity_id, message: "already has access to this entity" }

  validate :demo_and_real_books_stay_apart
  validate :owner_holds_no_entity


  # Orphaning is driven entirely by link changes, so both the sudo-unlink path
  # and the admin-deletion cascade (which destroys these rows) are covered here.
  after_create  :reconcile_orphan_state
  after_destroy :reconcile_orphan_state_after_removal

  scope :with_receipt_access, -> { where(access_level: [:full_access, :upload_receipts]) }
  scope :with_full_access, -> { where(access_level: :full_access) }
  scope :with_read_only, -> { where(access_level: :read_only) }

  # Two disjoint domains: sudo only ever removes a full_access row, and a full-
  # access admin only ever removes a read_only/upload_receipts row on an entity
  # they themselves hold full_access on.
  #
  # Checked against THIS ROW alone, never against the target admin's overall
  # status — an admin who is full_access somewhere else entirely is still an
  # ordinary coadmin on this entity. The single check both
  # AdminEntitiesController#destroy and admins/show.html.erb call.
  def removable_by?(admin)
    return full_access? if admin.sudo?
    return false if full_access?

    admin.full_access_entity_ids.include?(entity_id)
  end

  private

    # The demo door is public and takes no password, so a demo admin is a public
    # account — without this it is ONE ROW away from being a public account on
    # somebody's real books.
    #
    # Two rules, checked from both sides because either row can be created
    # second: a demo admin never holds full_access (read_only and
    # upload_receipts are both fine and both used — the demo offers a phone-only
    # uploader); and demo and real admins never share an entity.
    def demo_and_real_books_stay_apart
      return if admin.nil? || entity_id.nil?

      if admin.demo?
        errors.add(:access_level, "cannot be full_access for a demo admin") if full_access?
        if others_on_this_entity.joins(:admin).where(admins: { demo: false }).exists?
          errors.add(:entity_id, "belongs to a real admin and cannot also be reached by the public demo")
        end
      elsif others_on_this_entity.joins(:admin).where(admins: { demo: true }).exists?
        errors.add(:entity_id, "is reachable by the public demo and cannot also hold real books")
      end
    end

    # An owner sees and writes every entity regardless of any link, so a row
    # here would only ever SHRINK what they can reach through
    # Admin#can_use_archive? and friends, never grant anything. This is the
    # model-level guarantee that nothing can put one back.
    def owner_holds_no_entity
      errors.add(:admin_id, "is an owner — owners hold no entity links, they already see and write everything") if admin&.sudo?
    end

    def others_on_this_entity
      AdminEntity.where(entity_id: entity_id).where.not(admin_id: admin_id)
    end

    def reconcile_orphan_state
      entity&.refresh_orphan_state!
    end

    # If THIS removal is what orphaned the entity, notify the departing admin.
    # The job skips the email when the admin no longer exists — which is exactly
    # the admin-deletion cascade — so only a genuine "left this business" unlink
    # emails a still-existing person.
    def reconcile_orphan_state_after_removal
      ent = entity
      return if ent.nil? || ent.destroyed?

      was_orphaned = ent.orphaned?
      ent.refresh_orphan_state!
      return if was_orphaned || !ent.reload.orphaned?

      Entities::OrphanedNotificationJob.perform_later(
        entity_id: ent.id,
        admin_id: admin_id
      )
    end
end
