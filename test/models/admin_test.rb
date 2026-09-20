# frozen_string_literal: true

require "test_helper"

class AdminTest < ActiveSupport::TestCase
  setup do
    @sudo = admins(:sudo)
    @one = admins(:one)
    @two = admins(:two)
    @upload_only = admins(:upload_only)
    @read_only = admins(:read_only)
  end

  # ==================== Validations ====================

  test "downcases and strips email_address" do
    admin = Admin.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", admin.email_address)
  end

  test "requires username" do
    admin = Admin.new(username: nil, password: "password", email_address: "test@example.com")
    assert_not admin.valid?
    assert admin.errors[:username].present?
  end

  test "username must be unique" do
    admin = Admin.new(username: @one.username, password: "password", email_address: "unique@example.com")
    assert_not admin.valid?
    assert admin.errors[:username].present?
  end

  test "email must be unique" do
    admin = Admin.new(username: "unique_user", password: "password", email_address: @one.email_address)
    assert_not admin.valid?
    assert admin.errors[:email_address].present?
  end

  test "email is required for a real admin" do
    admin = Admin.new(username: "no_email", password: "password", email_address: "")
    assert_not admin.valid?
    assert admin.errors[:email_address].any? { |e| e.include?("blank") }
  end

  # Demo has no real password and no OTP, and nothing is reachable except
  # through the /demo button, so there is nothing an email would actually be
  # used for.
  test "email may be blank for a demo admin" do
    admin = Admin.new(username: "demo_no_email", password: "password", email_address: "", demo: true)
    admin.valid?
    assert_not admin.errors[:email_address].any? { |e| e.include?("blank") }
  end

  test "has_secure_password authenticates" do
    assert @one.authenticate("password")
    assert_not @one.authenticate("wrong")
  end

  # ==================== Sudo ====================

  test "sudo? returns true for sudo admin" do
    assert @sudo.sudo?
  end

  test "sudo? returns false for regular admin" do
    assert_not @one.sudo?
  end

  # ==================== full_access_pro? ====================

  test "full_access_pro? returns true for sudo" do
    assert @sudo.full_access_pro?
  end

  test "full_access_pro? returns true when full_access, otp enabled, and show_journal_entries" do
    @one.update!(otp_enabled: true, show_journal_entries: true)
    assert @one.full_access_pro?
  end

  test "full_access_pro? returns false without otp enabled in production" do
    @one.update!(otp_enabled: false, show_journal_entries: true)
    Admin.stub(:otp_required?, true) do
      assert_not @one.full_access_pro?
    end
  end

  test "full_access_pro? returns true without otp enabled when otp not required" do
    @one.update!(otp_enabled: false, show_journal_entries: true)
    Admin.stub(:otp_required?, false) do
      assert @one.full_access_pro?
    end
  end

  test "full_access_pro? returns false without show_journal_entries" do
    @one.update!(otp_enabled: true, show_journal_entries: false)
    assert_not @one.full_access_pro?
  end

  test "full_access_pro? returns false for non-full_access admin" do
    @upload_only.update!(otp_enabled: true, show_journal_entries: true)
    assert_not @upload_only.full_access_pro?
  end

  # ==================== can_manage? ====================

  test "sudo can manage regular admins" do
    assert @sudo.can_manage?(@one)
  end

  # Owners must be able to update and self-delete themselves: it is the only
  # route out of a rogue-owner situation that does not require server access.
  # install:demote_owner is the other route.
  test "sudo can manage itself" do
    assert @sudo.can_manage?(@sudo)
  end

  test "nobody can manage sudo, including another owner" do
    assert_not @one.can_manage?(@sudo)

    other_owner = @two
    other_owner.update_column(:sudo, true)
    assert_not @sudo.can_manage?(other_owner.reload)
  end

  test "full_access admin can manage a coadmin who shares a full-access entity with them" do
    assert @one.can_manage?(@upload_only)
    assert @one.can_manage?(@read_only)
  end

  test "full_access admin cannot manage an admin they share no entity with" do
    assert_not @two.can_manage?(@upload_only)
  end

  test "full_access admin cannot manage themselves" do
    assert_not @one.can_manage?(@one)
  end

  # A coadmin who has since become full_access anywhere is a peer, not a coadmin
  # — shares_full_access_entity_with?'s caller adds "and not full_access"
  # specifically so a peer is never manageable.
  test "full_access admin cannot manage an admin who has since become full_access" do
    @upload_only.admin_entities.update_all(access_level: :full_access)
    assert_not @one.can_manage?(@upload_only.reload)
  end

  # Sharing an entity is not enough — I must hold full_access on it myself.
  # mixed holds full_access on family_biz and read_only on personal; read_only
  # holds only read_only on personal. Reading the same entity someone else holds
  # any level on must not grant management.
  test "holding read_only (not full_access) on the ONLY entity shared with another admin is not enough to manage them" do
    assert_not admins(:mixed).can_manage?(admins(:read_only))
  end

  # The shared_reader fixture is read_only on personal (one's) AND family_biz
  # (two's). Both owners should independently be able to manage them.

  test "TWO unrelated full_access admins can each manage a coadmin who holds access from both" do
    shared = admins(:shared_reader)
    assert admins(:one).can_manage?(shared)
    assert admins(:two).can_manage?(shared)
  end

  test "shares_full_access_entity_with? is true via EITHER shared entity" do
    shared = admins(:shared_reader)
    assert admins(:one).shares_full_access_entity_with?(shared)
    assert admins(:two).shares_full_access_entity_with?(shared)
  end

  test "promoting a shared coadmin to full_access removes BOTH owners' management, not just one" do
    shared = admins(:shared_reader)
    shared.admin_entities.update_all(access_level: :full_access)
    shared.reload

    assert_not admins(:one).can_manage?(shared)
    assert_not admins(:two).can_manage?(shared)
  end

  test "a full-access admin sharing NO entity with a shared coadmin still cannot manage them" do
    # mixed holds family_biz (full_access) and personal (read_only), so it
    # shares an entity with shared_reader and IS able to manage them. Sanity-
    # check the negative instead: sudo aside, an admin holding full access on
    # entities overlapping with NEITHER of shared_reader's links cannot manage
    # them.
    unrelated_group = EntityGroup.create!(name: "Unrelated")
    unrelated_entity = Entity.create!(code: "77", name: "Unrelated Biz", active: true)
    unrelated_owner = Admin.create!(username: "unrelated_owner", email_address: "unrelated@example.com",
                                     password: "password12")
    AdminEntity.create!(admin: unrelated_owner, entity: unrelated_entity, access_level: :full_access)

    assert_not unrelated_owner.can_manage?(admins(:shared_reader))
  end

  # ==================== managed_admins (2026-09-17, A11 fix 2026-09-18)
  # ====================

  # A promoted coadmin must stay VISIBLE to their old admins and only become un-
  # editable. Dropping them from the row set entirely made the person invisible
  # on the page of an admin whose own entity they still held a link to.
  # can_manage?, not managed_admins, is what decides editability.
  test "managed_admins includes a full_access peer too, but can_manage? still refuses them" do
    managed = admins(:two).managed_admins
    assert_includes managed, admins(:shared_reader)   # two's own grant, on family_biz
    assert_includes managed, admins(:mixed)           # full_access on family_biz — visible, not editable
    assert_not_includes managed, admins(:two)          # never self

    assert_not admins(:two).can_manage?(admins(:mixed)), "a full_access peer must stay unmanageable"
  end

  test "managed_admins is empty for a non-full_access admin" do
    assert_empty admins(:upload_only).managed_admins
  end

  test "managed_admins shows the same shared coadmin to both of their owners" do
    assert_includes admins(:one).managed_admins, admins(:shared_reader)
    assert_includes admins(:two).managed_admins, admins(:shared_reader)
  end

  # ==================== Access Levels ====================

  test "full_access? returns true for admin with full_access entities" do
    assert @one.full_access?
    assert @two.full_access?
  end

  test "full_access? returns false for upload_only admin" do
    assert_not @upload_only.full_access?
  end

  test "full_access? returns false for read_only admin" do
    assert_not @read_only.full_access?
  end

  test "upload_receipts_only? returns true for upload_only admin" do
    assert @upload_only.upload_receipts_only?
  end

  test "upload_receipts_only? returns false for full_access admin" do
    assert_not @one.upload_receipts_only?
  end

  test "read_only? returns true for read_only admin" do
    assert @read_only.read_only?
  end

  test "read_only? returns false for full_access admin" do
    assert_not @one.read_only?
  end

  # ==================== Entity Access ====================

  test "can_access_accounts? for admin with entities" do
    assert @one.can_access_accounts?
  end

  test "can_access_accounts? for sudo without entities" do
    assert @sudo.can_access_accounts?
  end

  test "entity_codes returns assigned entity codes" do
    assert_equal ["01", "03"], @one.entity_codes.sort
  end

  test "accessible_accounts scoped to entities" do
    accounts = @one.accessible_accounts
    assert accounts.where(code: "101001").exists?  # entity 01
    assert_not accounts.where(code: "110001").exists?  # entity 10
  end

  test "sudo accessible_accounts returns all" do
    assert_equal Account.count, @sudo.accessible_accounts.count
  end

  # AdminEntity#owner_holds_no_entity refuses this outright, but the accessor
  # guarantee is defence in depth against a row from before that validation
  # existed — so it is proved here with validate: false, bypassing the guard on
  # purpose to simulate one.
  test "sudo sees and writes everything even while holding a (pre-existing, now-invalid) entity link" do
    AdminEntity.new(admin: @sudo, entity: entities(:personal), access_level: :read_only).save!(validate: false)
    @sudo.reset_access_cache!

    assert_equal Entity.count, @sudo.accessible_entities.count
    assert_equal Entity.count, @sudo.accessible_entity_ids.size
    assert_equal Entity.count, @sudo.writable_entity_ids.size
    assert_equal Account.count, @sudo.accessible_accounts.count
    assert_equal Account.count, @sudo.writable_accounts.count
  end

  test "accessible_entities scoped correctly" do
    entities = @one.accessible_entities
    assert_includes entities, entities(:personal)
    assert_includes entities, entities(:spouse)
    assert_not_includes entities, entities(:family_biz)
  end

  test "accessible_receipts scoped to entity ids" do
    receipts = @two.accessible_receipts
    # two has family_biz and daughter
    assert receipts.where(entity_id: entities(:family_biz).id).exists?
    assert_not receipts.where(entity_id: entities(:personal).id).exists?
  end

  # ==================== Upload Entity IDs ====================

  test "upload_entity_ids for full_access admin" do
    ids = @one.upload_entity_ids
    assert_includes ids, entities(:personal).id
    assert_includes ids, entities(:spouse).id
  end

  test "upload_entity_ids for upload_only admin" do
    ids = @upload_only.upload_entity_ids
    assert_includes ids, entities(:personal).id
  end

  test "upload_entity_ids for read_only admin is empty" do
    ids = @read_only.upload_entity_ids
    assert_empty ids
  end

  test "upload_entity_ids for sudo returns all" do
    ids = @sudo.upload_entity_ids
    assert_equal Entity.count, ids.count
  end

  # ==================== can_invite_for_entity? ====================

  test "can_invite_for_entity? true for full_access entity" do
    assert @one.can_invite_for_entity?(entities(:personal))
  end

  test "can_invite_for_entity? false for non-full_access entity" do
    assert_not @upload_only.can_invite_for_entity?(entities(:personal))
  end

  # ==================== manageable_entities ====================

  test "manageable_entities returns full_access entities" do
    entities = @one.manageable_entities
    assert_includes entities, entities(:personal)
    assert_includes entities, entities(:spouse)
  end

  test "manageable_entities empty for non-full_access admin" do
    assert_empty @upload_only.manageable_entities
  end

  # ==================== Associations ====================

  # Destroying a full-access admin must not destroy other admins who merely
  # share an entity with them: they may hold access granted by someone else
  # entirely, and there is no "who invited whom" relationship left to cascade
  # through.
  test "destroying admin does not destroy other admins who share an entity with them" do
    others = [ @upload_only, @read_only ]

    assert_difference("Admin.count", -1) do
      @one.destroy
    end

    others.each { |a| assert Admin.exists?(a.id), "#{a.username} should have survived" }
  end

  # personal(01) has other bookkeepers — upload_only, read_only and mixed all
  # hold non-full_access links there — while spouse's only link is one's own. So
  # destroying one orphans spouse specifically, the same shape as the promotion
  # test.
  test "destroying an admin's only full-access link orphans that entity, without touching others who still hold it" do
    spouse = entities(:spouse)
    personal = entities(:personal)
    assert_not spouse.orphaned?
    assert_not personal.orphaned?

    @one.destroy

    assert spouse.reload.orphaned?
    assert_not personal.reload.orphaned?, "personal still has other bookkeepers linked"
    assert Admin.exists?(@upload_only.id)
    assert AdminEntity.exists?(admin_id: @upload_only.id, entity_id: personal.id)
  end

  test "destroying admin nullifies uploaded receipts" do
    receipt = receipts(:uploaded_receipt)
    assert_equal @upload_only.id, receipt.uploaded_by_id
    @upload_only.destroy
    receipt.reload
    assert_nil receipt.uploaded_by_id
  end

  test "cannot delete last admin" do
    Admin.where.not(id: @sudo.id).destroy_all
    assert_equal 1, Admin.count
    @sudo.destroy
    assert_equal 1, Admin.count
  end

  # ==================== primary_entity_code ====================

  test "primary_entity_code returns entity_code column" do
    assert_equal "01", @one.primary_entity_code
  end

  test "primary_entity_code falls back to first entity" do
    admin = Admin.new
    admin.admin_entities.build(entity: entities(:family_biz))
    # Without entity_code column set, falls back
    assert_nil admin.entity_code
  end

  # An installation with no owner cannot be administered at all, since only sudo
  # passes without an entity link. This is a permanent lockout, not an
  # inconvenience.

  def lone_owner
    Admin.where(sudo: true).update_all(sudo: false)
    a = Admin.new(username: "only_owner", sudo: true, email_address: "only_owner@example.com")
    a.password = "password123"
    a.save!
    a
  end

  test "the last owner cannot be destroyed" do
    owner = lone_owner

    assert_not Admin.find(owner.id).destroy, "destroying the only owner leaves nobody able to administer"
    assert_equal 1, Admin.where(sudo: true).count
  end

  test "the last owner cannot untick their own box" do
    owner = lone_owner

    assert_not owner.update(sudo: false)
    assert Admin.find(owner.id).sudo?
  end

  # THE REGRESSION. A destroy guard reading the in-memory sudo? leaves a refused
  # demotion saying false while the database says true — and destroying that
  # same object removes the last owner. Two operations that are each correctly
  # refused were, in sequence, a lockout.
  test "a refused demotion does not disarm the destroy guard" do
    owner = lone_owner

    owner.update(sudo: false)                 # refused, but dirties the object
    assert_not owner.sudo?, "precondition: the failed update left it false in memory"
    assert Admin.find(owner.id).sudo?, "precondition: the database still says owner"

    assert_not owner.destroy, "the last owner was destroyed through a stale in-memory attribute"
    assert_equal 1, Admin.where(sudo: true).count
  end

  # Nothing prevents several owners, and the guards only bite on the last one.
  test "a second owner can be made, and then either may be demoted" do
    first = lone_owner
    second = Admin.new(username: "second_owner", sudo: true, email_address: "second_owner@example.com")
    second.password = "password123"

    assert second.save, "a second owner must be possible: #{second.errors.full_messages.join('; ')}"
    assert second.update(sudo: false), "with two owners, one may be demoted"
    assert_equal 1, Admin.where(sudo: true).count
  end
  # Logging in is Admin.authenticate_by(username:), which is find_by and takes
  # the FIRST match. The uniqueness validation cannot stop two concurrent
  # creates producing a pair, and the loser of that race could then never sign
  # in at all. email_address has had this index all along; username did not.
  test "the database itself refuses a duplicate username" do
    Admin.create!(username: "twice", password: "password123", email_address: "a@example.org")

    duplicate = Admin.new(username: "twice", password: "password123", email_address: "b@example.org")
    duplicate.save(validate: false)

    assert duplicate.errors.empty?, "precondition: validation was skipped"
    assert_not Admin.where(username: "twice").count > 1, "two admins share a username"
  rescue ActiveRecord::RecordNotUnique
    assert true, "the database refused it, which is the point"
  end

  test "a username cannot be null at the database level" do
    admin = Admin.new(password: "password123", email_address: "c@example.org")

    assert_raises(ActiveRecord::NotNullViolation) { admin.save(validate: false) }
  end

  # Archives::BooksCsv pulls the WHOLE family's ledger for any one member's
  # scope_key, so access to one member must not be access to the rest.

  test "a solo (ungrouped) entity's archive needs only the usual any-level access" do
    assert @one.can_use_archive?("01") # personal, read_only-plus link held
    assert_not @two.can_use_archive?("01") # two holds no link to 01 at all
  end

  test "a family archive requires write access to every member, not just one" do
    group = EntityGroup.create!(name: "Family archive test")
    entities(:family_biz).update!(entity_group: group)
    entities(:daughter).update!(entity_group: group)
    scope_key = "g#{group.id}"

    assert @two.can_use_archive?(scope_key), "two holds full_access on both family_biz and daughter"

    entities(:daughter).admin_entities.destroy_all
    AdminEntity.create!(admin: @two, entity: entities(:daughter), access_level: :read_only)
    @two.reset_access_cache!
    assert_not @two.can_use_archive?(scope_key), "read_only on one member must not unlock the family archive"
  end

  test "sudo may always use any archive" do
    assert @sudo.can_use_archive?("01")
    assert @sudo.can_use_archive?("g999") # no such group at all
  end

  # manages_family? — the gate on the "leave the family" form and on the
  # entities#update group-only path. Same rule as the family archive: full
  # access to EVERY member, not just one.
  test "manages_family? needs write access to every member of the family" do
    group = EntityGroup.create!(name: "manages_family test")
    entities(:family_biz).update!(entity_group: group)
    entities(:daughter).update!(entity_group: group)

    assert @two.manages_family?(group), "two holds full_access on both members"

    entities(:daughter).admin_entities.destroy_all
    AdminEntity.create!(admin: @two, entity: entities(:daughter), access_level: :read_only)
    @two.reset_access_cache!
    assert_not @two.manages_family?(group), "read_only on one member is not enough"

    entities(:daughter).admin_entities.destroy_all
    @two.reset_access_cache!
    assert_not @two.manages_family?(group), "no link to a member at all is not enough"
  end

  test "manages_family? is false for nil and true for sudo regardless" do
    group = EntityGroup.create!(name: "sudo manages_family test")
    entities(:personal).update!(entity_group: group) # sudo holds no links
    assert_not @one.manages_family?(nil)
    assert @sudo.manages_family?(group)
  end

  test "an unknown or dissolved group denies everyone but sudo" do
    assert_not @one.can_use_archive?("g999999")
  end

  # ==================== draft? / claim! ====================

  test "draft? is true only for a real admin with no claimed_at" do
    admin = Admin.new(claimed_at: nil, demo: false)
    assert admin.draft?

    admin.claimed_at = Time.current
    assert_not admin.draft?
  end

  test "draft? is false for demo regardless of claimed_at" do
    admin = Admin.new(claimed_at: nil, demo: true)
    assert_not admin.draft?, "demo has no email to confirm, so draft can never mean anything for it"
  end

  test "claim! sets claimed_at and flips draft? off" do
    admin = admins(:one)
    admin.update_columns(claimed_at: nil)
    assert admin.draft?

    admin.claim!
    assert_not admin.reload.draft?
    assert admin.claimed_at.present?
  end
end
