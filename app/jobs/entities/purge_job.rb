# frozen_string_literal: true

module Entities
  # Permanently erases an orphaned entity and ALL its data in the background.
  # Purge is irreversible and can be slow for a large entity, so it never runs
  # in the request cycle — the controller enqueues this after sudo confirms.
  #
  # Re-checks orphan state at run time: if an admin was re-linked (un-orphaning
  # the entity) or it was already purged before this ran, it does nothing.
  class PurgeJob < ApplicationJob
    queue_as :default

    def perform(entity_id)
      entity = Entity.find_by(id: entity_id)
      return if entity.nil? || !entity.orphaned?

      EntityPurgeService.call(entity)
    end
  end
end
