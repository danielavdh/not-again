# frozen_string_literal: true

module Entities
  # Monthly: finds orphaned entities whose 10-year retention period has passed
  # and emails sudo a review list. It NEVER deletes anything — deletion is
  # always
  # a deliberate, sudo-confirmed action (see EntitiesController#destroy).
  class RetentionSweepJob < ApplicationJob
    queue_as :default

    def perform
      due = Entity.due_for_deletion.order(:deletion_due_on).to_a
      return if due.empty?

      AdminMailer.with(entities: due).entities_due_for_deletion.deliver_now
    end
  end
end
