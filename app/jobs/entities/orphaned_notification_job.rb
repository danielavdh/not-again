# frozen_string_literal: true

module Entities
  # Emails the departing admin when their removal left an entity with no
  # bookkeepers (orphaned). Skips silently when the entity was re-linked before
  # this ran, or when the admin no longer exists — the latter being the
  # admin-deletion cascade, where there is no one to notify.
  class OrphanedNotificationJob < ApplicationJob
    queue_as :default

    def perform(entity_id:, admin_id:)
      entity = Entity.find_by(id: entity_id)
      admin  = Admin.find_by(id: admin_id)

      return if entity.nil? || !entity.orphaned?
      return if admin.nil? || admin.email_address.blank?

      AdminMailer.with(entity: entity, admin: admin).entity_orphaned_notice.deliver_now
    end
  end
end
