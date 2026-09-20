# frozen_string_literal: true
require "test_helper"

class EntitiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @entity = entities(:personal)
  end

  # --- Sudo-protected actions ---

  test "should get index" do
    sign_in_as(admins(:sudo))
    get entities_url(locale: :en)
    assert_response :success
  end

  test "should get new" do
    sign_in_as(admins(:sudo))
    get new_entity_url(locale: :en)
    assert_response :success
  end

  test "should create entity" do
    sign_in_as(admins(:sudo))
    assert_difference("Entity.count") do
      post entities_url(locale: :en), params: {
        entity: { name: "New Entity", code: "99", active: true }
      }
    end
    assert_redirected_to entity_url(Entity.last, locale: :en)
  end

  test "should show entity" do
    sign_in_as(admins(:sudo))
    get entity_url(locale: :en, id: @entity)
    assert_response :success
  end

  test "should get edit" do
    sign_in_as(admins(:sudo))
    get edit_entity_url(locale: :en, id: @entity)
    assert_response :success
  end

  test "should update entity" do
    sign_in_as(admins(:sudo))
    patch entity_url(locale: :en, id: @entity), params: {
      entity: { name: "Updated Name" }
    }
    assert_redirected_to entity_url(@entity, locale: :en)
    @entity.reload
    assert_equal "Updated Name", @entity.name
  end

  test "should enqueue a background purge for an orphaned entity" do
    sign_in_as(admins(:sudo))
    entity = Entity.create!(name: "To Delete", code: "88", active: true)
    entity.update_columns(orphaned_at: Time.current, deletion_due_on: Date.current)
    assert_enqueued_with(job: Entities::PurgeJob, args: [entity.id]) do
      delete entity_url(locale: :en, id: entity)
    end
    assert_redirected_to entities_url(locale: :en)
  end

  test "should NOT enqueue a purge for an entity that still has admins" do
    sign_in_as(admins(:sudo))
    live = entities(:personal) # has admin links → not orphaned
    assert_no_enqueued_jobs(only: Entities::PurgeJob) do
      delete entity_url(locale: :en, id: live)
    end
    assert Entity.exists?(live.id)
  end

  test "an admin can leave (unlink from) an entity" do
    sign_in_as(admins(:one))
    entity = entities(:spouse) # admin :one is the only link
    assert_difference("AdminEntity.where(entity_id: #{entity.id}).count", -1) do
      delete leave_entity_url(locale: :en, id: entity)
    end
    assert entity.reload.orphaned?, "entity should be orphaned after its last admin leaves"
  end

  # SELF_SERVICE_ACTIONS exempts :leave from the sudo gate, but BaseController's
  # require_write_access runs on EVERY action regardless and redirected these
  # two away before #leave's own logic ever ran. Invisible until a coadmin could
  # reach their own page to click the button at all.
  test "a read_only admin can leave, despite the write-access gate" do
    coadmin = admins(:read_only)
    entity = coadmin.entities.first
    sign_in_as(coadmin)

    assert_difference("AdminEntity.count", -1) do
      delete leave_entity_url(locale: :en, id: entity)
    end
    assert_not AdminEntity.exists?(admin_id: coadmin.id, entity_id: entity.id)
  end

  test "an upload_receipts_only admin can leave, despite the write-access gate" do
    coadmin = admins(:upload_only)
    entity = coadmin.entities.first
    sign_in_as(coadmin)

    assert_difference("AdminEntity.count", -1) do
      delete leave_entity_url(locale: :en, id: entity)
    end
    assert_not AdminEntity.exists?(admin_id: coadmin.id, entity_id: entity.id)
  end

  # --- business family (consolidation group) via update ---

  test "sudo sets an entity's business family through update" do
    sign_in_as(admins(:sudo))
    patch entity_url(@entity, locale: :en), params: {
      entity: { name: @entity.name, code: @entity.code, active: "1", group_value: "Household" }
    }
    assert_equal "Household", @entity.reload.entity_group&.name
  end

  test "a full-access admin can set the family group-only (from admin/show)" do
    sign_in_as(admins(:one)) # holds 01 and 03
    patch entity_url(@entity, locale: :en), params: {
      group_only: 1, entity: { group_value: "Mine" }
    }
    assert_equal "Mine", @entity.reload.entity_group&.name
  end

  test "a full-access admin cannot do a full entity update" do
    sign_in_as(admins(:one))
    patch entity_url(@entity, locale: :en), params: {
      entity: { name: "Hacked", code: @entity.code, active: "1" }
    }
    assert_response :forbidden
    assert_not_equal "Hacked", @entity.reload.name
  end

  test "a full-access admin cannot join a family whose members they do not hold" do
    sign_in_as(admins(:one)) # holds 01, 03 — not 10
    others = EntityGroup.create!(name: "Others")
    entities(:family_biz).update!(entity_group: others) # entity 10
    patch entity_url(@entity, locale: :en), params: {
      group_only: 1, entity: { group_value: others.id }
    }
    assert_response :forbidden
    assert_nil @entity.reload.entity_group_id
  end

  # An entity already in a family is never offered a MOVE to a different family
  # here — only sudo does that, via the entity's own full edit page. The
  # family_field's picker looks identical whether an entity is ungrouped or in a
  # family its own admin cannot fully see, so silently moving it would be as
  # invisible as silently ungrouping it.
  #
  # LEAVING, clearing to none, is different: allowed, and gated by the model's
  # own three-condition check.
  test "a full-access admin cannot move an already-grouped entity to a different family" do
    sign_in_as(admins(:one)) # holds 01, 03
    original = EntityGroup.create!(name: "Original Family")
    @entity.update!(entity_group: original)
    mine = EntityGroup.create!(name: "Mine")

    patch entity_url(@entity, locale: :en), params: {
      group_only: 1, entity: { group_value: mine.id }
    }

    assert_response :forbidden
    assert_equal original.id, @entity.reload.entity_group_id
  end

  test "a full-access admin can leave an already-grouped family once untangled, checkbox ticked" do
    sign_in_as(admins(:one))
    original = EntityGroup.create!(name: "Original Family")
    @entity.update!(entity_group: original)

    patch entity_url(@entity, locale: :en), params: { group_only: 1, entity: { leave_family: "1" } }

    assert_response :redirect
    assert_nil @entity.reload.entity_group_id
  end

  # Daniela's report / audit I4: holding full access to ONE member of a family
  # is not permission to change the family. The leave must be refused.
  test "a full-access admin cannot leave a family whose other members they do not hold" do
    sign_in_as(admins(:one)) # holds personal, not the sibling below
    family = EntityGroup.create!(name: "Half Held")
    @entity.update!(entity_group: family)
    Entity.create!(name: "Sibling one cannot write", code: "87", active: true, entity_group: family)

    patch entity_url(@entity, locale: :en), params: { group_only: 1, entity: { leave_family: "1" } }

    assert_response :forbidden
    assert_equal family.id, @entity.reload.entity_group_id
  end

  # The form has no group_value at all for an already-grouped entity, only the
  # checkbox — so a plain submit with it unticked, or the field simply absent,
  # must change nothing and never fall through to "blank means leave".
  test "submitting the leave form without ticking the checkbox is a no-op" do
    sign_in_as(admins(:one))
    original = EntityGroup.create!(name: "Original Family")
    @entity.update!(entity_group: original)

    patch entity_url(@entity, locale: :en), params: { group_only: 1, entity: {} }

    assert_response :redirect
    assert_equal original.id, @entity.reload.entity_group_id
  end

  test "a full-access admin cannot leave while entangled with a sibling's report group" do
    sign_in_as(admins(:one)) # holds 01 and 03
    original = EntityGroup.create!(name: "Original Family")
    sibling  = entities(:spouse)
    @entity.update!(entity_group: original)
    sibling.update!(entity_group: original)
    account = Account.create!(code: "103001", name: "Spouse account", account_type: :asset, active: true)
    rg = @entity.report_groups.create!(name: "Consolidated")
    rg.report_group_accounts.create!(account: account, position: 0)

    patch entity_url(@entity, locale: :en), params: { group_only: 1, entity: { leave_family: "1" } }

    assert_response :redirect
    assert_equal original.id, @entity.reload.entity_group_id
  end

  test "sudo is unaffected by the already-grouped guard" do
    sign_in_as(admins(:sudo))
    original = EntityGroup.create!(name: "Original Family")
    @entity.update!(entity_group: original)

    patch entity_url(@entity, locale: :en), params: {
      entity: { name: @entity.name, code: @entity.code, active: "1", group_value: "" }
    }

    assert_nil @entity.reload.entity_group_id
  end
end