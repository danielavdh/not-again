# frozen_string_literal: true

require "test_helper"

# Down to one action, `destroy`. Granting goes through AdminsController's
# unified admin-creation form for both sudo and a full-access admin.
class AdminEntitiesControllerTest < ActionDispatch::IntegrationTest
  test "the old index/new/create routes are gone" do
    assert_raises(NameError) { admin_entities_path }
    assert_raises(NameError) { new_admin_entity_path }
  end

  test "sudo may destroy any admin_entity, on any entity" do
    sign_in_as(admins(:sudo))
    ae = admin_entities(:two_daughter)

    assert_difference("AdminEntity.count", -1) do
      delete admin_entity_url(ae, locale: :en)
    end
    assert_redirected_to admins_path(locale: :en)
  end

  test "a full-access admin may destroy a link on an entity they hold full_access on" do
    sign_in_as(admins(:one)) # full_access on personal
    ae = admins(:upload_only).admin_entities.find_by(entity_id: entities(:personal).id)

    assert_difference("AdminEntity.count", -1) do
      delete admin_entity_url(ae, locale: :en)
    end
    assert_redirected_to admin_path(admins(:one), locale: :en)
  end

  test "a full-access admin cannot destroy a link on an entity they do not hold full_access on" do
    sign_in_as(admins(:one))
    ae = admin_entities(:two_family_biz) # two's entity, not one's

    assert_no_difference("AdminEntity.count") do
      delete admin_entity_url(ae, locale: :en)
    end
    assert_redirected_to dashboard_path
  end

  # can_manage?'s "peer" rule, checked against this ROW's own entity: a
  # full_access target is never removable by a full-access admin, even on an
  # entity they genuinely manage.
  test "a full-access admin cannot destroy a link belonging to a full_access peer" do
    sign_in_as(admins(:one)) # full_access on personal AND spouse
    peer_link = AdminEntity.create!(admin: admins(:mixed), entity: entities(:spouse), access_level: :full_access)

    assert_no_difference("AdminEntity.count") do
      delete admin_entity_url(peer_link, locale: :en)
    end
  end

  # Granting a full-access-elsewhere admin read_only on MY entity must not leave
  # that grant permanently stuck. Checking the ADMIN's overall status —
  # full_access ANYWHERE — instead of THIS ROW's own level did exactly that:
  # being a peer on entity 05 protected a read_only row on entity 01 that has
  # nothing to do with it.
  test "a full-access admin CAN destroy a read_only link, even when its owner is a full_access peer on a different entity" do
    sign_in_as(admins(:one)) # full_access on personal
    peer = Admin.create!(username: "peer_elsewhere", email_address: "peer_elsewhere@example.com",
                          password: "password", password_confirmation: "password")
    AdminEntity.create!(admin: peer, entity: entities(:standalone), access_level: :full_access)
    link = AdminEntity.create!(admin: peer, entity: entities(:personal), access_level: :read_only)

    assert_difference("AdminEntity.count", -1) do
      delete admin_entity_url(link, locale: :en)
    end
    assert AdminEntity.exists?(admin_id: peer.id, entity_id: entities(:standalone).id),
           "the peer's own full_access entity must be untouched"
  end

  # The symmetric case: a SECOND full-access admin on the same entity must be
  # able to revoke it too, not only the original granter — the same rule as
  # granting.
  test "a SECOND full-access admin on the same entity can also destroy that read_only link" do
    second = Admin.create!(username: "second_owner", email_address: "second_owner@example.com",
                            password: "password", password_confirmation: "password",
                            claimed_at: Time.current,
                            terms_agreed_version: Admin::TERMS_VERSION, terms_agreed_at: Time.current)
    AdminEntity.create!(admin: second, entity: entities(:personal), access_level: :full_access)

    peer = Admin.create!(username: "peer_elsewhere2", email_address: "peer_elsewhere2@example.com",
                          password: "password", password_confirmation: "password")
    AdminEntity.create!(admin: peer, entity: entities(:standalone), access_level: :full_access)
    link = AdminEntity.create!(admin: peer, entity: entities(:personal), access_level: :read_only)

    sign_in_as(second)
    assert_difference("AdminEntity.count", -1) do
      delete admin_entity_url(link, locale: :en)
    end
  end

  test "read_only and upload_receipts admins cannot destroy anything here" do
    ae = admin_entities(:two_daughter)

    sign_in_as(admins(:read_only))
    assert_no_difference("AdminEntity.count") { delete admin_entity_url(ae, locale: :en) }
    assert_redirected_to dashboard_path
    sign_out

    sign_in_as(admins(:upload_only))
    assert_no_difference("AdminEntity.count") { delete admin_entity_url(ae, locale: :en) }
    assert_redirected_to upload_standalone_receipts_path
  end

  test "unauthenticated cannot destroy anything here" do
    ae = admin_entities(:two_daughter)
    assert_no_difference("AdminEntity.count") do
      delete admin_entity_url(ae, locale: :en)
    end
  end
end
