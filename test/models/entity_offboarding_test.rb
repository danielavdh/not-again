# frozen_string_literal: true
require "test_helper"

class EntityOffboardingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  test "removing the last admin orphans the entity and notifies the departing admin" do
    entity = entities(:spouse) # linked only to admin :one
    assert_not entity.orphaned?

    assert_enqueued_with(job: Entities::OrphanedNotificationJob) do
      admin_entities(:one_spouse).destroy
    end

    entity.reload
    assert entity.orphaned?
    assert_equal Date.current + Entity::RETENTION_YEARS.years, entity.deletion_due_on
  end

  test "re-adding an admin clears the orphan state" do
    entity = entities(:spouse)
    admin_entities(:one_spouse).destroy
    assert entity.reload.orphaned?

    AdminEntity.create!(admin: admins(:one), entity: entity, access_level: :full_access)
    assert_not entity.reload.orphaned?
    assert_nil entity.deletion_due_on
  end

  test "removing a non-last admin does not orphan the entity" do
    entity = entities(:personal) # three admin links
    admin_entities(:read_only_personal).destroy
    assert_not entity.reload.orphaned?
  end

  test "purge refuses a live entity and deletes an orphaned one" do
    assert_raises(ArgumentError) { EntityPurgeService.call(entities(:personal)) }

    entity = entities(:standalone)
    entity.update_columns(orphaned_at: Time.current, deletion_due_on: Date.current)
    EntityPurgeService.call(entity)
    assert_not Entity.exists?(entity.id)
  end

  test "purge deletes the entity's Scaleway scan files" do
    entity = entities(:family_biz) # has receipt fixtures with scans
    entity.update_columns(orphaned_at: Time.current, deletion_due_on: Date.current)
    scans = Receipt.where(entity_id: entity.id).count
    assert scans.positive?, "fixture guard: family_biz must have scanned receipts"

    # delete_all skips Shrine callbacks, so the service enqueues one idempotent
    # DestroyJob per file to erase it from Scaleway.
    assert_enqueued_jobs(scans, only: DestroyJob) do
      EntityPurgeService.call(entity)
    end
    assert_equal 0, Receipt.where(entity_id: entity.id).count
  end

  test "the purge job only erases an entity that is still orphaned" do
    live = entities(:personal)
    assert_no_difference("Entity.count") { Entities::PurgeJob.perform_now(live.id) }
    assert_no_difference("Entity.count") { Entities::PurgeJob.perform_now(-1) }

    entity = entities(:standalone)
    entity.update_columns(orphaned_at: Time.current, deletion_due_on: Date.current)
    Entities::PurgeJob.perform_now(entity.id)
    assert_not Entity.exists?(entity.id)
  end

  test "monthly sweep emails only when entities are due" do
    assert_no_emails { Entities::RetentionSweepJob.perform_now }

    entities(:standalone).update_columns(orphaned_at: 11.years.ago, deletion_due_on: 1.year.ago)
    assert_emails(1) { Entities::RetentionSweepJob.perform_now }
  end
end
