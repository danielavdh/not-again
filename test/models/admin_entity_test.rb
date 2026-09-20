# frozen_string_literal: true

require "test_helper"

class AdminEntityTest < ActiveSupport::TestCase
  setup do
    @one_personal = admin_entities(:one_personal)
    @upload_only_personal = admin_entities(:upload_only_personal)
    @read_only_personal = admin_entities(:read_only_personal)
  end

  # ==================== Validations ====================

  test "valid admin_entity" do
    assert @one_personal.valid?
  end

  test "cannot assign same entity twice to same admin" do
    duplicate = AdminEntity.new(
      admin: admins(:one),
      entity: entities(:personal),
      access_level: :full_access
    )
    assert_not duplicate.valid?
    assert duplicate.errors[:admin_id].present?
  end

  test "same admin can have different entities" do
    ae = AdminEntity.new(
      admin: admins(:one),
      entity: entities(:standalone),
      access_level: :full_access
    )
    assert ae.valid?
  end

  test "same entity can be assigned to different admins" do
    ae = AdminEntity.new(
      admin: admins(:two),
      entity: entities(:personal),
      access_level: :read_only
    )
    assert ae.valid?
  end

  # ==================== Access Level Enum ====================

  test "full_access is default (0)" do
    ae = AdminEntity.new
    assert_equal "full_access", ae.access_level
  end

  test "access_level enum values" do
    assert_equal 0, AdminEntity.access_levels[:full_access]
    assert_equal 1, AdminEntity.access_levels[:upload_receipts]
    assert_equal 2, AdminEntity.access_levels[:read_only]
  end

  test "full_access? predicate" do
    assert @one_personal.full_access?
    assert_not @upload_only_personal.full_access?
    assert_not @read_only_personal.full_access?
  end

  test "upload_receipts? predicate" do
    assert @upload_only_personal.upload_receipts?
    assert_not @one_personal.upload_receipts?
  end

  test "read_only? predicate" do
    assert @read_only_personal.read_only?
    assert_not @one_personal.read_only?
  end

  # ==================== Scopes ====================

  test "with_receipt_access includes full_access and upload_receipts" do
    scope = AdminEntity.with_receipt_access
    assert_includes scope, @one_personal
    assert_includes scope, @upload_only_personal
    assert_not_includes scope, @read_only_personal
  end

  test "with_full_access only includes full_access" do
    scope = AdminEntity.with_full_access
    assert_includes scope, @one_personal
    assert_not_includes scope, @upload_only_personal
    assert_not_includes scope, @read_only_personal
  end

  test "with_read_only only includes read_only" do
    scope = AdminEntity.with_read_only
    assert_includes scope, @read_only_personal
    assert_not_includes scope, @one_personal
    assert_not_includes scope, @upload_only_personal
  end

  # ==================== Associations ====================

  test "belongs to admin" do
    assert_equal admins(:one), @one_personal.admin
  end

  test "belongs to entity" do
    assert_equal entities(:personal), @one_personal.entity
  end

  # An owner sees and writes everything regardless of any link, so a link here
  # would only ever shrink what they can reach, never grant anything. Promotion
  # clears any existing links.

  test "an entity cannot be granted to an owner" do
    link = AdminEntity.new(admin: admins(:sudo), entity: entities(:standalone), access_level: :full_access)

    assert_not link.valid?
    assert link.errors[:admin_id].present?
  end

  # The /demo door is public and takes no password, so a demo admin is a public
  # account. These try to turn one into a public account on real books — which
  # without the validation takes exactly one row.

  def demo_admin(username = "demo_test")
    Admin.create!(username: username, password: "password123", demo: true, sudo: false)
  end

  test "a demo admin cannot hold full_access on anything" do
    link = AdminEntity.new(admin: demo_admin, entity: entities(:standalone), access_level: :full_access)

    assert_not link.valid?, "a public passwordless account must never hold write access"
    assert link.errors[:access_level].present?
  end

  test "a demo admin cannot reach an entity a real admin already uses" do
    link = AdminEntity.new(admin: demo_admin, entity: entities(:personal), access_level: :read_only)

    assert_not link.valid?, "entity :personal belongs to admin :one — the public demo must not read it"
    assert link.errors[:entity_id].present?
  end

  test "a real admin cannot join an entity the demo can reach" do
    entity = entities(:standalone)
    AdminEntity.create!(admin: demo_admin, entity: entity, access_level: :read_only)

    link = AdminEntity.new(admin: admins(:two), entity: entity, access_level: :full_access)

    assert_not link.valid?, "real books must not become readable through the public demo door"
    assert link.errors[:entity_id].present?
  end

  # Both directions matter because either row can be the one created second.
  test "the guard holds whichever link is created first" do
    entity = entities(:standalone)
    AdminEntity.create!(admin: admins(:two), entity: entity, access_level: :full_access)

    link = AdminEntity.new(admin: demo_admin, entity: entity, access_level: :read_only)
    assert_not link.valid?
  end

  # ⚠️ Must stay allowed: the demo deliberately offers a phone-only uploader, so
  # "demo means read_only" would be wrong and would break `demo:seed`.
  test "a demo admin may still upload receipts to a demo-only entity" do
    entity = entities(:standalone)
    entity.admin_entities.destroy_all

    link = AdminEntity.new(admin: demo_admin, entity: entity, access_level: :upload_receipts)

    assert link.valid?, "the upload-only demo is a feature: #{link.errors.full_messages.join('; ')}"
  end

  test "two demo admins may share a demo entity" do
    entity = entities(:standalone)
    entity.admin_entities.destroy_all
    AdminEntity.create!(admin: demo_admin("demo_a"), entity: entity, access_level: :read_only)

    link = AdminEntity.new(admin: demo_admin("demo_b"), entity: entity, access_level: :upload_receipts)

    assert link.valid?, "demo:seed creates three demo admins on one entity: #{link.errors.full_messages.join('; ')}"
  end
end
