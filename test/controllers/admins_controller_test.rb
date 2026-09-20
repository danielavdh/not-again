# frozen_string_literal: true

require "test_helper"

class AdminsControllerTest < ActionDispatch::IntegrationTest

  # ==================== Sudo Tests ====================

  class SudoAdminTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:sudo)
      sign_in_as(@admin)
    end

    test "should get index" do
      get admins_url(locale: :en)
      assert_response :success
    end

    test "should get new" do
      get new_admin_url(locale: :en)
      assert_response :success
    end

    test "should create admin without entity_code" do
      assert_difference("Admin.count") do
        assert_no_difference("Entity.count") do
          post admins_url(locale: :en), params: {
            admin: {
              username: "newadmin",
              password: "password",
              password_confirmation: "password",
              email_address: "newadmin@example.com"
            }
          }
        end
      end
      assert_redirected_to admins_url(locale: :en)
    end

    # Founding a new entity at admin-creation time is retired — that is
    # entities#new. entity_code is still a permitted param, edited directly and
    # unrelated to this flow, but has no effect on entity or AdminEntity
    # creation, so a crafted request carrying it is simply ignored.
    test "entity_code has no effect on admin creation any more" do
      assert_difference("Admin.count") do
        assert_no_difference([ "Entity.count", "AdminEntity.count" ]) do
          post admins_url(locale: :en), params: {
            admin: {
              username: "newadmin",
              password: "password",
              password_confirmation: "password",
              email_address: "newadmin@example.com",
              entity_code: "99"
            }
          }
        end
      end
      assert_redirected_to admins_url(locale: :en)
    end

    # Sudo grants through this same action. Dispatch is on whether any
    # entity_ids were checked: none means create_as_sudo (a bare admin, covered
    # above), one or more means the grant path.
    #
    # Sudo has no level to choose — granting an entity IS granting full_access,
    # unconditionally. The list is every active entity, not just sudo's own,
    # since sudo holds none.

    test "sudo grants are always full_access, with no level param at all" do
      entity = entities(:standalone)
      assert_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: { username: "new_owner", password: "password", password_confirmation: "password",
                   email_address: "new_owner@example.com" },
          entity_ids: [ entity.id ]
        }
      end
      new_admin = Admin.find_by(username: "new_owner")
      assert new_admin.admin_entities.exists?(entity_id: entity.id, access_level: :full_access)
    end

    test "sudo granting to an EXISTING admin adds full_access alongside whatever they already hold" do
      shared = admins(:shared_reader) # already read_only on personal
      entity = entities(:standalone)

      assert_no_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: { email_address: shared.email_address },
          entity_ids: [ entity.id ]
        }
      end
      assert AdminEntity.exists?(admin_id: shared.id, entity_id: entity.id, access_level: :full_access)
      assert AdminEntity.exists?(admin_id: shared.id, entity_id: entities(:personal).id),
             "the existing read_only grant must survive"
    end

    test "sudo's entity list reaches every active entity, not just sudo's own (sudo has none)" do
      all_ids = Entity.active.pluck(:id)
      assert_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: { username: "all_entities_admin", password: "password", password_confirmation: "password",
                   email_address: "all_entities_admin@example.com" },
          entity_ids: all_ids
        }
      end
      new_admin = Admin.find_by(username: "all_entities_admin")
      assert_equal all_ids.sort, new_admin.admin_entities.pluck(:entity_id).sort
      assert new_admin.admin_entities.all?(&:full_access?)
    end

    # A crafted request trying to sneak a lesser level past sudo's own form
    # (which never submits access_level at all) must not work either.
    test "sudo cannot be downgraded to read_only by a crafted access_level param" do
      entity = entities(:standalone)
      post admins_url(locale: :en), params: {
        admin: { username: "cannot_downgrade", password: "password", password_confirmation: "password",
                 email_address: "cannot_downgrade@example.com" },
        entity_ids: [ entity.id ],
        access_level: "read_only"
      }
      assert Admin.find_by(username: "cannot_downgrade").admin_entities.exists?(access_level: :full_access)
    end

    test "create fails with duplicate username" do
      assert_no_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: {
            username: admins(:one).username,
            password: "password",
            password_confirmation: "password",
            email_address: "different@example.com"
          }
        }
      end
      assert_response :unprocessable_entity
    end

    test "should show admin" do
      get admin_url(admins(:one), locale: :en)
      assert_response :success
    end

    # Grant Access is a general "go create or grant" shortcut, not an action
    # about whoever @admin happens to be: showing it while sudo looks at someone
    # ELSE's page read like granting access to that person specifically, which
    # it never was.
    test "Grant Access shows on sudo's own page but not while viewing another admin's" do
      get admin_url(@admin, locale: :en)
      assert_select "a[href=?]", new_admin_path, text: "Grant Access"

      get admin_url(admins(:one), locale: :en)
      assert_select "a[href=?]", new_admin_path, text: "Grant Access", count: 0
    end

    # This page is about the ADMIN — identity, access, family. Tax setup and
    # filing are about the entity, and live on the entity's own dashboard block.
    test "the admin page carries no tax setup or filing buttons" do
      sign_in_as(@admin)
      get admin_url(@admin, locale: :en)
      assert_response :success
      assert_select "a[href*=?]", "edit_tax", count: 0
    end

    # Q5: taxpayers are reached from the tax setup page, and from here too — but
    # only once you actually have one, or the link is a dead end.
    test "the profile offers Manage taxpayers only once the admin has one" do
      sign_in_as(admins(:one))

      get admin_path(admins(:one), locale: :en)
      assert_response :success
      assert_select "a[href^=?]", "/en/taxpayers", count: 0

      admins(:one).taxpayers.create!(authority: "hmrc", label: "A client")
      get admin_path(admins(:one), locale: :en)
      assert_select "a[href^=?]", "/en/taxpayers", count: 1
    end

    # On the ACCOUNTS host: this page answers on both, and everything that acts
    # on accounts data is shown only there. The main-host counterpart is
    # test/integration/admins_on_accounts_host_test.rb.
    test "a full-access admin sees a leave button for each of their own entities" do
      sign_in_as(admins(:one)) # full-access, linked to :personal and :spouse
      # A PATH, not admin_url: the _url helper builds an absolute address from
      # the default host and would send this to the main site regardless of
      # host!.
      get admin_path(admins(:one), locale: :en)
      assert_response :success
      assert_match %r{entities/#{entities(:personal).id}/leave}, response.body
      assert_match %r{entities/#{entities(:spouse).id}/leave}, response.body
    end

    test "sudo viewing another admin's show sees no leave button" do
      get admin_url(admins(:one), locale: :en) # signed in as sudo (see setup)
      assert_response :success
      assert_no_match %r{entities/\d+/leave}, response.body
    end

    test "should get edit" do
      get edit_admin_url(admins(:one), locale: :en)
      assert_response :success
    end

    test "should update admin" do
      patch admin_url(admins(:one), locale: :en), params: {
        admin: { username: admins(:one).username }
      }
      assert_redirected_to admins_url(locale: :en)
    end

    test "should update admin password" do
      patch admin_url(admins(:one), locale: :en), params: {
        admin: { password: "newpassword", password_confirmation: "newpassword" }
      }
      assert_redirected_to admins_url(locale: :en)
      admins(:one).reload
      assert admins(:one).authenticate("newpassword")
    end

    test "update ignores blank password" do
      old_digest = admins(:one).password_digest
      patch admin_url(admins(:one), locale: :en), params: {
        admin: { username: admins(:one).username, password: "", password_confirmation: "" }
      }
      assert_redirected_to admins_url(locale: :en)
      admins(:one).reload
      assert_equal old_digest, admins(:one).password_digest
    end

    test "should destroy admin" do
      other_admin = admins(:two)
      assert_difference("Admin.count", -1) do
        delete admin_url(other_admin, locale: :en)
      end
      assert_redirected_to admins_url(locale: :en)
    end

    # The LAST owner cannot self-destroy — ensure_an_owner_remains refuses it.
    # @admin is the fixture's only sudo, so this is about the last owner
    # specifically, not about self-destroy in general (see the next test).
    test "the last owner cannot destroy self" do
      assert_no_difference("Admin.count") do
        delete admin_url(@admin, locale: :en)
      end
    end

    # An owner MAY remove themselves once a second owner exists — the self-
    # service route out of a rogue-owner situation, alongside
    # install:demote_owner for when the rogue owner is the one still signed in.
    test "an owner can destroy self once a second owner exists" do
      admins(:one).update_column(:sudo, true)
      assert_difference("Admin.count", -1) do
        delete admin_url(@admin, locale: :en)
      end
    end

    # No cascade: destroying a full-access admin must not destroy other admins
    # who merely share an entity with them, since they may hold access granted
    # by someone else.
    test "destroying admin does not destroy other admins who share an entity with them" do
      admin_one = admins(:one)
      others = [ admins(:upload_only), admins(:read_only) ]

      assert_difference("Admin.count", -1) do
        delete admin_url(admin_one, locale: :en)
      end

      others.each { |a| assert Admin.exists?(a.id) }
    end
  end

  # ==================== Full-Access Admin Tests ====================

  class FullAccessAdminTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:one)  # full_access to personal and spouse
      sign_in_as(@admin)
    end

    test "index is sudo only - redirects full_access admin" do
      get admins_url(locale: :en)
      assert_redirected_to dashboard_path
    end

    test "can view own show page" do
      get admin_url(@admin, locale: :en)
      assert_response :success
    end

    test "cannot view other admin show page" do
      get admin_url(admins(:two), locale: :en)
      # Should redirect: one and two share no entity at all
      assert_response :redirect
    end

    # Viewing another admin's page is retired entirely, even for a coadmin one
    # invited oneself — set_admin only ever hands a non-sudo admin their OWN
    # record. What a full-access admin needs to know about a coadmin lives on
    # the authorised table on their own page.
    test "cannot view an invited admin's own show page any more" do
      get admin_url(admins(:upload_only), locale: :en)
      assert_redirected_to dashboard_path
    end

    test "cannot view a coadmin's page even when access was granted by a DIFFERENT owner" do
      sign_in_as(admins(:two))
      get admin_url(admins(:shared_reader), locale: :en)
      assert_redirected_to dashboard_path
    end

    # A coadmin promoted to full_access elsewhere must stay VISIBLE on the
    # authorised table of the admin whose entity they still hold a link to, and
    # only become un-editable: no Remove button, and no Edit button at all any
    # more, for anyone.
    test "a coadmin promoted to full_access elsewhere stays listed, with no Remove button" do
      coadmin = admins(:upload_only)
      coadmin.admin_entities.update_all(access_level: :full_access)

      get admin_url(@admin, locale: :en)
      assert_response :success
      assert_match coadmin.username, response.body
      # Not "no Edit anywhere" — @admin is viewing their OWN page, which
      # legitimately carries an Edit link for themselves. Scoped to: no remove
      # form for THIS coadmin's row.
      assert_select "form[action=?]", admin_entity_path(coadmin.admin_entities.first), count: 0
    end

    # The Remove button must not disappear for a read_only row just because its
    # owner is ALSO full_access on some unrelated entity. The row itself has
    # nothing to do with that.
    test "a coadmin who is full_access elsewhere still gets a Remove button for a read_only row on MY entity" do
      coadmin = admins(:read_only) # read_only on personal, one's own entity
      AdminEntity.create!(admin: coadmin, entity: entities(:standalone), access_level: :full_access)
      link = coadmin.admin_entities.find_by(entity_id: entities(:personal).id)

      get admin_url(@admin, locale: :en)
      assert_response :success
      assert_select "form[action=?]", admin_entity_path(link), count: 1
    end

    test "should get new for co-admin invite" do
      get new_admin_url(locale: :en)
      assert_response :success
    end

    # Username and password sit in a <details> closed by default, opened by JS
    # only once the email is confirmed to belong to nobody. This is the fresh-
    # load state: no email submitted, so the server has nothing to go on and
    # stays closed rather than guessing.
    test "on a fresh load, username/password are closed by default" do
      get new_admin_url(locale: :en)
      assert_select "details#new-person-fields[open]", 0
      assert_select "details#new-person-fields", 1
    end

    # The server-rendered state on an error reload: it already knows the
    # submitted email, so it computes the correct open/closed state directly
    # rather than defaulting closed and waiting for JS.
    test "on an error reload, an existing email keeps the details closed" do
      post admins_url(locale: :en), params: {
        admin: { email_address: admins(:shared_reader).email_address },
        access_level: "bogus", # forces the unprocessable_entity re-render
        entity_ids: [ entities(:daughter).id ]
      }
      assert_response :unprocessable_entity
      assert_select "details#new-person-fields[open]", 0
    end

    test "on an error reload, a genuinely new email opens the details" do
      post admins_url(locale: :en), params: {
        admin: { email_address: "genuinely_new_person@example.com" },
        access_level: "bogus",
        entity_ids: [ entities(:daughter).id ]
      }
      assert_response :unprocessable_entity
      assert_select "details#new-person-fields[open]", 1
    end

    test "email_lookup answers whether an email belongs to an existing admin" do
      get email_lookup_admins_url(email: admins(:shared_reader).email_address, locale: :en)
      assert_equal({ "exists" => true }, JSON.parse(response.body))

      get email_lookup_admins_url(email: "nobody_at_all@example.com", locale: :en)
      assert_equal({ "exists" => false }, JSON.parse(response.body))
    end

    test "email_lookup is refused to read_only, upload_receipts and signed-out visitors" do
      sign_out
      get email_lookup_admins_url(email: "x@example.com", locale: :en)
      assert_response :redirect, "signed out must not reach it"

      sign_in_as(admins(:read_only))
      get email_lookup_admins_url(email: "x@example.com", locale: :en)
      assert_response :redirect

      sign_in_as(admins(:upload_only))
      get email_lookup_admins_url(email: "x@example.com", locale: :en)
      assert_response :redirect
    end

    # The password field must not be client-side required on this page: when the
    # email resolves to an EXISTING admin the password is never read at all
    # (grant_existing_admin_access ignores it), and there is no way to know
    # which case it will be before the request is sent.
    test "the password field is not required client-side on the grant form" do
      get new_admin_url(locale: :en)
      assert_select "input#admin_password[required]", 0
    end

    test "should create co-admin with upload_receipts access" do
      assert_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: {
            username: "new_coadmin",
            password: "password",
            password_confirmation: "password",
            email_address: "coadmin@example.com"
          },
          access_level: "upload_receipts",
          entity_ids: [ entities(:personal).id, entities(:spouse).id ]
        }
      end
      new_admin = Admin.find_by(username: "new_coadmin")
      assert new_admin.admin_entities.all?(&:upload_receipts?)
    end

    test "should create co-admin with read_only access" do
      assert_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: {
            username: "new_reader",
            password: "password",
            password_confirmation: "password",
            email_address: "reader_new@example.com"
          },
          access_level: "read_only",
          entity_ids: [ entities(:personal).id, entities(:spouse).id ]
        }
      end
      new_admin = Admin.find_by(username: "new_reader")
      assert new_admin.admin_entities.all?(&:read_only?)
    end

    test "cannot create co-admin with full_access" do
      assert_no_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: {
            username: "hacker",
            password: "password",
            password_confirmation: "password"
          },
          access_level: "full_access",
          entity_ids: [ entities(:personal).id ]
        }
      end
      assert_redirected_to new_admin_path
    end

    test "cannot create co-admin with invalid access level" do
      assert_no_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: {
            username: "hacker2",
            password: "password",
            password_confirmation: "password"
          },
          access_level: "bogus",
          entity_ids: [ entities(:personal).id ]
        }
      end
      assert_redirected_to new_admin_path
    end

    test "create co-admin with specific entities" do
      entity = entities(:personal)
      assert_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: {
            username: "specific_coadmin",
            password: "password",
            password_confirmation: "password",
            email_address: "specific_coadmin@example.com"
          },
          access_level: "upload_receipts",
          entity_ids: [entity.id]
        }
      end
      new_admin = Admin.find_by(username: "specific_coadmin")
      assert_equal [entity.id], new_admin.admin_entities.pluck(:entity_id)
    end

    test "create co-admin fails without entities" do
      assert_no_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: {
            username: "no_entities",
            password: "password",
            password_confirmation: "password"
          },
          access_level: "upload_receipts",
          entity_ids: []
        }
      end
      assert_response :unprocessable_entity
    end

    # Granting access to an EXISTING admin — the shared-accountant case: two
    # unrelated full-access admins, one bookkeeper. Looked up by email only,
    # never username (see find_existing_coadmin_candidate); creates an
    # AdminEntity link, never a second Admin row, and never touches their
    # password or username.

    test "granting access to an existing admin's email links them, creates no new admin" do
      shared = admins(:shared_reader) # already exists, read_only on personal
      daughter = entities(:daughter)  # two's, shared_reader has no link here yet
      original_password_digest = shared.password_digest
      sign_in_as(admins(:two))

      assert_no_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: { username: "ignored", password: "ignored123", email_address: shared.email_address },
          access_level: "upload_receipts",
          entity_ids: [ daughter.id ]
        }
      end

      shared.reload
      assert AdminEntity.exists?(admin_id: shared.id, entity_id: daughter.id, access_level: "upload_receipts")
      assert_equal "shared_reader", shared.username, "existing admin's own username must not change"
      assert_equal original_password_digest, shared.password_digest, "existing admin's own password must not change"
      assert AdminEntity.exists?(admin_id: shared.id, entity_id: entities(:personal).id),
             "the FIRST owner's (one's) existing grant must not be touched by a SECOND owner's grant"
    end

    # A2's open question, resolved 2026-09-19: an existing admin is told,
    # not just silently linked.
    test "granting access to an existing admin's email notifies them" do
      shared = admins(:shared_reader)
      daughter = entities(:daughter)
      sign_in_as(admins(:two))

      assert_enqueued_email_with AdminMailer, :access_granted,
        params: { admin: shared, granter: admins(:two), entities: [ daughter ], level: "upload_receipts", locale: :en } do
        post admins_url(locale: :en), params: {
          admin: { email_address: shared.email_address },
          access_level: "upload_receipts",
          entity_ids: [ daughter.id ]
        }
      end
    end

    test "granting access to an existing admin who is already linked to every selected entity sends no notification" do
      shared = admins(:shared_reader) # already read_only on personal
      sign_in_as(admins(:one))

      assert_no_enqueued_emails do
        post admins_url(locale: :en), params: {
          admin: { email_address: shared.email_address },
          access_level: "upload_receipts",
          entity_ids: [ entities(:personal).id ]
        }
      end
    end

    test "granting an existing admin access still refuses full_access" do
      shared = admins(:shared_reader)
      sign_in_as(admins(:two))

      post admins_url(locale: :en), params: {
        admin: { email_address: shared.email_address },
        access_level: "full_access",
        entity_ids: [ entities(:daughter).id ]
      }

      assert_redirected_to new_admin_path
      assert_not AdminEntity.exists?(admin_id: shared.id, entity_id: entities(:daughter).id)
    end

    test "granting access when already linked to every selected entity is a no-op, not a duplicate" do
      shared = admins(:shared_reader) # already read_only on family_biz
      sign_in_as(admins(:two))

      assert_no_difference([ "Admin.count", "AdminEntity.count" ]) do
        post admins_url(locale: :en), params: {
          admin: { email_address: shared.email_address },
          access_level: "upload_receipts",
          entity_ids: [ entities(:family_biz).id ]
        }
      end
    end

    # new.html.erb must render the flash partial: the alert is SET on the
    # redirect, and without it is only ever displayed once the admin happens to
    # navigate somewhere else that does render one.
    test "the already_linked refusal is actually visible on the page it redirects to" do
      shared = admins(:shared_reader)
      sign_in_as(admins(:two))

      post admins_url(locale: :en), params: {
        admin: { email_address: shared.email_address },
        access_level: "upload_receipts",
        entity_ids: [ entities(:family_biz).id ]
      }
      assert_redirected_to new_admin_path
      follow_redirect!
      assert_match I18n.t("admins.already_linked", username: shared.email_address), response.body
    end

    test "granting access to sudo's email is refused, not silently linked" do
      sign_in_as(admins(:two))

      assert_no_difference("AdminEntity.count") do
        post admins_url(locale: :en), params: {
          admin: { email_address: admins(:sudo).email_address },
          access_level: "read_only",
          entity_ids: [ entities(:daughter).id ]
        }
      end
    end

    # An owner's email reuses already_linked rather than a dedicated "that is an
    # owner's email" message: a distinct reason would be an oracle confirming
    # which emails belong to owners. It is also literally true — an owner
    # already has access to every entity. Without the check it falls through to
    # Admin.new.save and fails on email uniqueness with a generic message.
    test "granting access to sudo's email reuses already_linked, not a generic uniqueness error" do
      sign_in_as(admins(:two))

      assert_no_difference([ "AdminEntity.count", "Admin.count" ]) do
        post admins_url(locale: :en), params: {
          admin: { email_address: admins(:sudo).email_address },
          access_level: "read_only",
          entity_ids: [ entities(:daughter).id ]
        }
      end
      assert_redirected_to new_admin_path
      follow_redirect!
      assert_no_match(/already been taken/i, response.body)
      assert_match I18n.t("admins.already_linked", username: admins(:sudo).email_address), response.body
    end

    test "granting access to yourself by your own email creates a normal new admin instead" do
      sign_in_as(admins(:two))
      # current_admin's own email is excluded from the lookup, so this falls
      # through to the ordinary "create a new admin" path and fails there on a
      # duplicate email, exactly as it would for anyone else's.
      assert_no_difference("Admin.count") do
        post admins_url(locale: :en), params: {
          admin: { username: "should_not_exist", password: "password1", email_address: admins(:two).email_address },
          access_level: "read_only",
          entity_ids: [ entities(:daughter).id ]
        }
      end
    end

    # A claimed coadmin owns their own identity fields: a full-access admin no
    # longer edits or updates another admin's account at all, invited or not,
    # because set_admin never hands them anyone else.
    test "cannot edit an invited admin's account any more" do
      get edit_admin_url(admins(:upload_only), locale: :en)
      assert_redirected_to dashboard_path
    end

    test "cannot update an invited admin's account any more" do
      original_username = admins(:upload_only).username
      patch admin_url(admins(:upload_only), locale: :en), params: {
        admin: { username: "updated_uploader" }
      }
      assert_redirected_to dashboard_path
      assert_equal original_username, admins(:upload_only).reload.username
    end

    # Access level is not settable through AdminsController#update at all. It
    # lives on the grant and remove actions — create's existing-admin path, and
    # AdminEntitiesController#destroy — never on an edit form.
    test "cannot change a coadmin's access level via AdminsController#update" do
      patch admin_url(admins(:upload_only), locale: :en), params: {
        admin: { username: admins(:upload_only).username },
        access_level: "read_only"
      }
      assert_redirected_to dashboard_path
      assert admins(:upload_only).reload.admin_entities.all?(&:upload_receipts?)
    end

    # "Remove" is per (coadmin, entity), on AdminEntitiesController#destroy,
    # reached from the authorised table's own row rather than
    # AdminsController#destroy. The account survives regardless — a coadmin may
    # hold access granted by a different owner.
    test "removing a coadmin's link on my entity destroys only that AdminEntity row" do
      coadmin = admins(:upload_only)
      link = coadmin.admin_entities.find_by(entity_id: entities(:personal).id)

      assert_no_difference("Admin.count") do
        assert_difference("AdminEntity.count", -1) do
          delete admin_entity_url(link, locale: :en)
        end
      end
      assert_redirected_to admin_path(@admin, locale: :en)
      assert_not AdminEntity.exists?(link.id)
    end

    test "removing one entity's link never touches a link granted by another owner" do
      shared = admins(:shared_reader) # read_only on personal (mine) AND family_biz (two's)
      link = shared.admin_entities.find_by(entity_id: entities(:personal).id)

      delete admin_entity_url(link, locale: :en)

      assert Admin.exists?(shared.id)
      assert_not AdminEntity.exists?(admin_id: shared.id, entity_id: entities(:personal).id)
      assert AdminEntity.exists?(admin_id: shared.id, entity_id: entities(:family_biz).id),
             "two's grant must survive one removing their own"
    end

    # Attacking the boundary directly: entity 03 is not one of MINE, so even
    # though the row exists and belongs to a coadmin I do share ANOTHER entity
    # with, this specific row must refuse.
    test "cannot remove a link on an entity I do not hold full_access on" do
      shared = admins(:shared_reader)
      link = shared.admin_entities.find_by(entity_id: entities(:family_biz).id) # two's, not mine

      assert_no_difference("AdminEntity.count") do
        delete admin_entity_url(link, locale: :en)
      end
      assert AdminEntity.exists?(link.id)
    end

    test "cannot destroy admin not invited by self" do
      assert_no_difference("Admin.count") do
        delete admin_url(admins(:two), locale: :en)
      end
    end

    # HTTP-level, not just the model predicate: two can reach and remove THEIR
    # OWN grant through the authorised table on their own page, without ever
    # being able to view shared_reader's page directly.
    test "the SECOND owner can remove their own grant via HTTP, end to end, without viewing the coadmin's page" do
      shared = admins(:shared_reader) # personal (one's) and family_biz (two's)
      link = shared.admin_entities.find_by(entity_id: entities(:family_biz).id)
      sign_in_as(admins(:two))

      get admin_url(shared, locale: :en)
      assert_redirected_to dashboard_path

      get admin_url(admins(:two), locale: :en)
      assert_match shared.username, response.body

      delete admin_entity_url(link, locale: :en)
      assert_response :redirect
      assert Admin.exists?(shared.id)
      assert_not AdminEntity.exists?(admin_id: shared.id, entity_id: entities(:family_biz).id)
      assert AdminEntity.exists?(admin_id: shared.id, entity_id: entities(:personal).id),
             "one's grant must survive two removing their own"
    end

    test "cannot destroy sudo" do
      assert_no_difference("Admin.count") do
        delete admin_url(admins(:sudo), locale: :en)
      end
    end
  end

  # A grant to a brand-new email leaves the account a draft (claimed_at nil)
  # until the person themselves logs in and claims it. See Admin#draft?/#claim!,
  # GatesController#claim_show/claim_update, and
  # AdminsController#destroy_draft_as_full_access_admin/#resend_claim_email.
  class DraftClaimTests < ActionDispatch::IntegrationTest
    setup do
      @granter = admins(:one) # full_access on personal, spouse
      sign_in_as(@granter)
    end

    test "granting a brand-new email creates a draft" do
      post admins_url(locale: :en), params: {
        admin: { username: "coadmin_draft", password: "grantergiven1",
                 password_confirmation: "grantergiven1", email_address: "coadmin_draft@example.com" },
        access_level: "read_only",
        entity_ids: [ entities(:personal).id ]
      }
      draft = Admin.find_by(username: "coadmin_draft")
      assert draft.draft?
      assert_nil draft.claimed_at
    end

    test "create_as_sudo never creates a draft" do
      sign_out
      sign_in_as(admins(:sudo))
      post admins_url(locale: :en), params: {
        admin: { username: "sudo_made", password: "password", password_confirmation: "password",
                 email_address: "sudo_made@example.com" }
      }
      assert_not Admin.find_by(username: "sudo_made").draft?
    end

    test "sudo's grant (an entity checked for an existing coadmin) does not touch claimed_at on an already-claimed admin" do
      sign_out
      sign_in_as(admins(:sudo))
      target = admins(:upload_only)
      assert_not target.draft?
      post admins_url(locale: :en), params: {
        admin: { email_address: target.email_address },
        entity_ids: [ entities(:daughter).id ]
      }
      assert_not target.reload.draft?
    end

    test "the granter can destroy a draft they created outright" do
      draft = create_draft(granter: @granter, entity: entities(:personal))

      assert_difference("Admin.count", -1) do
        delete admin_url(draft, locale: :en)
      end
      assert_redirected_to admin_path(@granter, locale: :en)
    end

    test "the granter cannot destroy a coadmin who has already claimed their account" do
      draft = create_draft(granter: @granter, entity: entities(:personal))
      draft.claim!

      assert_no_difference("Admin.count") do
        delete admin_url(draft, locale: :en)
      end
      assert Admin.exists?(draft.id)
    end

    test "a second full-access admin sharing the same entity may also destroy the draft (symmetric with can_manage?)" do
      other_full_access = Admin.create!(username: "co_owner_personal", email_address: "co_owner@example.com",
                                         password: "password", password_confirmation: "password",
                                         claimed_at: Time.current,
                                         terms_agreed_version: Admin::TERMS_VERSION, terms_agreed_at: Time.current)
      AdminEntity.create!(admin: other_full_access, entity: entities(:personal), access_level: :full_access)
      draft = create_draft(granter: @granter, entity: entities(:personal))

      sign_out
      sign_in_as(other_full_access)
      assert_difference("Admin.count", -1) do
        delete admin_url(draft, locale: :en)
      end
    end

    test "cannot destroy a draft granted on an entity not shared with self" do
      draft = create_draft(granter: @granter, entity: entities(:personal))

      sign_out
      sign_in_as(admins(:two)) # full_access on family_biz/daughter only
      assert_no_difference("Admin.count") do
        delete admin_url(draft, locale: :en)
      end
      assert Admin.exists?(draft.id)
    end

    test "resend_claim_email re-delivers the verification email for a draft" do
      draft = create_draft(granter: @granter, entity: entities(:personal))

      assert_enqueued_email_with AdminMailer, :email_verification,
                                 params: { admin: draft, granter: @granter, locale: :en } do
        post resend_claim_email_admin_url(draft, locale: :en)
      end
      assert_redirected_to admin_path(@granter, locale: :en)
    end

    test "resend_claim_email is refused once the coadmin has claimed their account" do
      draft = create_draft(granter: @granter, entity: entities(:personal))
      draft.claim!

      # set_admin's draft branch only ever finds an UNCLAIMED admin, so a
      # claimed one 404s into the standard "not found" redirect before
      # resend_claim_email's own draft? guard is reached.
      post resend_claim_email_admin_url(draft, locale: :en)
      assert_redirected_to admin_path(@granter, locale: :en)
      assert_match I18n.t("admins.not_found"), flash[:alert]
    end

    test "the authorised table shows a draft label and Resend/Remove, not the ordinary per-entity Remove" do
      draft = create_draft(granter: @granter, entity: entities(:personal))

      get admin_url(@granter, locale: :en)
      assert_response :success
      assert_match draft.email_address, response.body
      assert_select "form[action=?]", resend_claim_email_admin_path(draft)
      assert_select "form[action=?]", admin_path(draft)
      link = draft.admin_entities.find_by(entity_id: entities(:personal).id)
      assert_select "form[action=?]", admin_entity_path(link), count: 0
    end

    private

    def create_draft(granter:, entity:, level: "read_only")
      post admins_url(locale: :en), params: {
        admin: { username: "draft_#{SecureRandom.hex(4)}", password: "grantergiven1",
                 password_confirmation: "grantergiven1", email_address: "draft_#{SecureRandom.hex(4)}@example.com" },
        access_level: level,
        entity_ids: [ entity.id ]
      }
      Admin.where(claimed_at: nil).order(:created_at).last
    end
  end

  # A full-access admin editing themselves gets its own mode: no access_level
  # field, no entity checkboxes, access shown as text only.
  #
  # Rendering the coadmin form for a self-edit meant an access_level select that
  # never even lists "full_access" — and submitting it, as the browser does with
  # whatever option IS in the list, silently demoted the admin's own entity
  # access.
  class SelfEditTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:one) # full_access on personal and spouse
      sign_in_as(@admin)
    end

    test "edit renders self mode, not invite mode" do
      get edit_admin_url(@admin, locale: :en)
      assert_response :success
      assert_select "select#access_level", 0, "the coadmin access-level dropdown was shown on a self-edit page"
      assert_select "#entity-checkboxes", 0
    end

    test "editing self can change email, username and password without touching entity access" do
      patch admin_url(@admin, locale: :en), params: {
        admin: { email_address: "renamed@example.com", username: "admin_one_renamed",
                 password: "newpassword1", password_confirmation: "newpassword1" }
      }

      @admin.reload
      assert_equal "renamed@example.com", @admin.email_address
      assert_equal "admin_one_renamed", @admin.username
      assert @admin.authenticate("newpassword1")
      assert @admin.full_access?, "self-edit touched entity access levels"
      assert_equal 2, @admin.admin_entities.count, "self-edit touched entity assignments"
    end

    # Submitting access_level — as the browser would, since the select only ever
    # offers read_only and upload_receipts — must not change anything. Full-
    # access admins do not set their own access level.
    test "submitting an access_level param on self-edit is ignored" do
      before_levels = @admin.admin_entities.pluck(:access_level)

      patch admin_url(@admin, locale: :en), params: {
        admin: { email_address: @admin.email_address },
        access_level: "read_only"
      }

      assert_equal before_levels, @admin.reload.admin_entities.pluck(:access_level)
    end

    test "show page offers an Edit link for a full-access admin's own profile" do
      get admin_url(@admin, locale: :en)
      assert_select "a[href=?]", edit_admin_path(@admin), text: "Edit"
    end
  end

  # Edit must not be gated on full_access?, stale from before self-access opened
  # to every admin; and Grant Access needs a gate of its own, or the button
  # shows to someone the server will refuse.
  class ReadOnlyAndUploadOnlySelfViewTests < ActionDispatch::IntegrationTest
    test "a read_only admin's own show page offers Edit, not Grant Access" do
      admin = admins(:read_only)
      sign_in_as(admin)

      get admin_url(admin, locale: :en)
      assert_select "a[href=?]", edit_admin_path(admin), text: "Edit"
      assert_select "a", text: "Grant Access", count: 0
    end

    test "an upload_receipts admin's own show page offers Edit, not Grant Access" do
      admin = admins(:upload_only)
      sign_in_as(admin)

      get admin_url(admin, locale: :en)
      assert_select "a[href=?]", edit_admin_path(admin), text: "Edit"
      assert_select "a", text: "Grant Access", count: 0
    end

    test "a read_only admin can actually reach and use their own edit form" do
      admin = admins(:read_only)
      sign_in_as(admin)

      get edit_admin_url(admin, locale: :en)
      assert_response :success

      patch admin_url(admin, locale: :en), params: { admin: { username: "renamed_reader" } }
      assert_equal "renamed_reader", admin.reload.username
    end
  end

  # An entity already in a family is never offered a picker at all — it looks
  # identical to an ungrouped one otherwise. "Available" needs at least two
  # entities that are full_access and ungrouped, or there is nothing to form a
  # family FROM, so the picker is hidden entirely below that.
  class FamilyFieldVisibilityTests < ActionDispatch::IntegrationTest
    # personal is grouped into a family with a HIDDEN sibling the admin does not
    # hold, so it is excluded from assignable_entity_groups, leaving spouse the
    # only available entity with no existing family to join either. Nothing to
    # do, so the picker disappears for BOTH, not just the grouped one.
    test "an already-grouped entity shows the fact, and the picker disappears with nothing to join or pair with" do
      admin = admins(:one) # full_access on personal and spouse, both ungrouped
      family = EntityGroup.create!(name: "Real Family")
      entities(:personal).update!(entity_group: family)
      Entity.create!(name: "Hidden sibling", code: "88", active: true, entity_group: family) # admin has no access to this
      sign_in_as(admin)

      get admin_url(admin, locale: :en)

      # Assert the KEY's current value rather than hardcoding text this test
      # cannot change — the wording lives in the locale file.
      assert_match I18n.t("entities.group.in_family"), response.body
      assert_select "#entity_group_value", 0
      # ...and no leave form: the admin does not fully hold this family
      # (the hidden sibling), so they may not change it.
      assert_select "input[name=?]", "entity[leave_family]", 0
    end

    # The report Daniela filed: fictive2 holds full access to ONE member of a
    # three-member family. They see the fact, never the leave form.
    test "a grouped entity whose family the admin only partly holds shows no leave form" do
      admin  = admins(:one) # full_access on personal, NOT on the sibling below
      family = EntityGroup.create!(name: "Half Held")
      entities(:personal).update!(entity_group: family)
      Entity.create!(name: "Sibling one cannot write", code: "87", active: true, entity_group: family)
      sign_in_as(admin)

      get admin_url(admin, locale: :en)

      assert_match I18n.t("entities.group.in_family"), response.body   # the fact still shows
      assert_select "input[name=?]", "entity[leave_family]", 0        # but not the form
    end

    test "with three held entities, one already grouped, the other two still show pickers" do
      admin = admins(:one) # personal and spouse, plus a third below
      third = Entity.create!(name: "Third", code: "84", active: true)
      AdminEntity.create!(admin: admin, entity: third, access_level: :full_access)
      EntityGroup.create!(name: "Real Family").entities << entities(:personal)
      sign_in_as(admin)

      get admin_url(admin, locale: :en)

      assert_select "#entity_group_value", 2 # spouse and third, not personal
    end

    test "two ungrouped full_access entities still show the picker for both" do
      admin = admins(:one) # personal and spouse, both ungrouped — the ordinary case
      sign_in_as(admin)

      get admin_url(admin, locale: :en)

      assert_select "#entity_group_value", 2
    end

    # 01, 02 and 03 already share a family the admin fully holds; 06 does not
    # yet. available_count sees just one ungrouped entity and would hide its
    # picker entirely — but adding 06 to a family she already fully holds is
    # legitimate and must be offered.
    test "an admin who fully holds an existing family can still add one more ungrouped entity to it" do
      admin = admins(:one) # personal(01) and spouse(03) already held, both go into the family
      e06 = Entity.create!(name: "06", code: "86", active: true)
      family = EntityGroup.create!(name: "01-03")
      entities(:personal).update!(entity_group: family)
      entities(:spouse).update!(entity_group: family)
      AdminEntity.create!(admin: admin, entity: e06, access_level: :full_access)
      sign_in_as(admin)

      get admin_url(admin, locale: :en)

      # Only one entity is available and only one family is assignable, so there
      # is no point offering "create a new group" — this is the plain select,
      # not the create-capable TomSelect. Even with a single family it carries a
      # "choose" prompt and nothing is pre-selected: joining a family is always
      # a deliberate choice.
      assert_select "select#entity_group_value", 0
      assert_select "select[name=?]", "entity[group_value]" do
        assert_select "option[selected]", 0
        assert_select "option[value=?]", family.id.to_s, text: "01-03"
      end
    end

    # The picker's "at least two available" gate is about JOINING — forming or
    # growing a family. Leaving has no such gate: a single already-grouped
    # entity, with nothing else available at all, still gets its own "Leave the
    # family" checkbox, labelled with the family's actual name.
    test "an already-grouped entity always gets the leave checkbox, regardless of available_count, with the group's name" do
      admin = admins(:one)
      EntityGroup.create!(name: "Real Family").entities << entities(:personal)
      sign_in_as(admin)

      get admin_url(admin, locale: :en)

      assert_select "input[type=checkbox][name=?]", "entity[leave_family]", 1
      assert_match "Real Family", response.body
    end

    # Only ONE entity is available, so "create a new group" is off the table,
    # but TWO existing families are assignable — the plain select needs a real
    # choice between them, so neither is pre-selected.
    test "one available entity but two assignable families shows a plain choice, not pre-selected" do
      admin = admins(:one)
      AdminEntity.where(admin: admin).destroy_all # start clean: no personal/spouse links
      family_a = EntityGroup.create!(name: "Family A")
      family_b = EntityGroup.create!(name: "Family B")
      in_a  = Entity.create!(name: "In A", code: "84", active: true, entity_group: family_a)
      in_b  = Entity.create!(name: "In B", code: "85", active: true, entity_group: family_b)
      alone = Entity.create!(name: "Alone", code: "86", active: true) # the only ungrouped one
      [in_a, in_b, alone].each { |e| AdminEntity.create!(admin: admin, entity: e, access_level: :full_access) }
      sign_in_as(admin)

      get admin_url(admin, locale: :en)

      assert_select "select#entity_group_value", 0 # not the TomSelect branch
      assert_select "select[name=?]", "entity[group_value]" do
        assert_select "option[selected]", 0
        assert_select "option[value=?]", family_a.id.to_s
        assert_select "option[value=?]", family_b.id.to_s
      end
    end
  end

  # ==================== update_preferences ====================

  class UpdatePreferencesTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:one)
      sign_in_as(@admin)
    end

    test "admin can enable show_journal_entries for themselves" do
      patch update_preferences_admin_url(@admin, locale: :en),
            params: { admin: { show_journal_entries: "1" } }
      assert_redirected_to admin_url(@admin, locale: :en)
      assert @admin.reload.show_journal_entries?
    end

    test "admin can disable show_journal_entries for themselves" do
      @admin.update!(show_journal_entries: true)
      patch update_preferences_admin_url(@admin, locale: :en),
            params: { admin: { show_journal_entries: "0" } }
      assert_redirected_to admin_url(@admin, locale: :en)
      assert_not @admin.reload.show_journal_entries?
    end

    # set_admin refuses before update_preferences' own action ever runs now —
    # a non-sudo admin can no longer be handed anyone else's id at all.
    test "admin cannot update preferences for another admin" do
      other = admins(:two)
      patch update_preferences_admin_url(other, locale: :en),
            params: { admin: { show_journal_entries: "1" } }
      assert_redirected_to dashboard_path
      assert_not other.reload.show_journal_entries?
    end

    test "admin can set and clear a preferred report currency" do
      patch update_preferences_admin_url(@admin, locale: :en),
            params: { admin: { preferred_currency: "GBP" } }
      assert_equal "GBP", @admin.reload.preferred_currency

      # blank means "work it out from my accounts", the default behaviour
      patch update_preferences_admin_url(@admin, locale: :en),
            params: { admin: { preferred_currency: "" } }
      assert_nil @admin.reload.preferred_currency
    end

    # Each preference has its own form, so posting one must not reset the other.
    test "saving one preference leaves the other alone" do
      @admin.update!(show_journal_entries: true, preferred_currency: "CHF")

      patch update_preferences_admin_url(@admin, locale: :en),
            params: { admin: { preferred_currency: "GBP" } }
      assert @admin.reload.show_journal_entries?, "the checkbox must survive a currency save"

      patch update_preferences_admin_url(@admin, locale: :en),
            params: { admin: { show_journal_entries: "0" } }
      assert_equal "GBP", @admin.reload.preferred_currency, "the currency must survive a checkbox save"
    end

    test "admin can set and clear a preferred number format" do
      patch update_preferences_admin_url(@admin, locale: :en),
            params: { admin: { preferred_number_format: "ch" } }
      assert_equal "ch", @admin.reload.preferred_number_format

      patch update_preferences_admin_url(@admin, locale: :en),
            params: { admin: { preferred_number_format: "" } }
      assert_nil @admin.reload.preferred_number_format
    end
  end

  # ==================== Unauthorized Access Tests ====================

  class UnauthorizedAccessTests < ActionDispatch::IntegrationTest
    test "upload_only admin cannot access admins controller" do
      sign_in_as(admins(:upload_only))
      get admins_url(locale: :en)
      assert_redirected_to dashboard_path
    end

    test "read_only admin cannot access admins controller" do
      sign_in_as(admins(:read_only))
      get admins_url(locale: :en)
      assert_redirected_to dashboard_path
    end

    test "unauthenticated user cannot access admins" do
      get admins_url(locale: :en)
      assert_response :redirect
    end
  end

  # Ownership is not something a coadmin can hand out. can_manage? lets a full-
  # access admin edit the admins they manage, so permitting :sudo for them would
  # let them make one an owner and have that owner make them one — escalation in
  # two steps, from an account never meant to reach the admin list at all.
  class OwnershipTests < ActionDispatch::IntegrationTest
    test "a full-access admin cannot grant ownership to an admin they manage" do
      inviter = admins(:one)
      invitee = Admin.create!(username: "invitee", password: "password12",
                              email_address: "invitee@example.com")
      AdminEntity.create!(admin: invitee, entity: entities(:personal), access_level: :read_only)

      sign_in_as inviter
      patch admin_url(invitee, locale: :en), params: { admin: { sudo: "1" } }

      refute invitee.reload.sudo?, "a co-admin must not be able to hand out ownership"
    end

    test "an owner can grant ownership" do
      sign_in_as admins(:sudo)
      other = admins(:one)

      patch admin_url(other, locale: :en), params: { admin: { sudo: "1" } }

      assert other.reload.sudo?
    end

    test "the last owner cannot be un-ticked" do
      owner = admins(:sudo)
      assert_equal 1, Admin.where(sudo: true).count, "fixture assumption"

      owner.sudo = false

      refute owner.valid?, "removing the last owner locks everyone out of admin management"
      assert_match(/last owner/, owner.errors.full_messages.join)
    end

    test "the last owner cannot be destroyed" do
      owner = admins(:sudo)
      assert_equal 1, Admin.where(sudo: true).count, "fixture assumption"

      refute owner.destroy, "destroying the last owner locks everyone out"
      assert Admin.exists?(owner.id)
    end
  end

  # verify_email has to be reachable with no session at all — a fresh invite
  # opens the mail link before ever signing in — and by every access level, so
  # it skips ensure_full_access, require_otp_verification and
  # require_terms_agreement.
  class VerifyEmailTests < ActionDispatch::IntegrationTest
    test "an unauthenticated visitor can confirm a valid token" do
      admin = admins(:one)
      admin.update!(verified_at: nil)
      token = admin.generate_token_for(:email_verification)

      get verify_email_url(token, locale: :en)

      assert_redirected_to new_session_path(locale: :en)
      assert admin.reload.verified?
    end

    test "an invalid token is rejected without touching any admin" do
      get verify_email_url("bogus", locale: :en)

      assert_redirected_to new_session_path(locale: :en)
      assert_not admins(:one).reload.verified?
    end

    test "a signed-in admin confirming their own link lands on the dashboard" do
      admin = admins(:one)
      admin.update!(verified_at: nil)
      token = admin.generate_token_for(:email_verification)
      sign_in_as admin

      get verify_email_url(token, locale: :en)

      assert_redirected_to dashboard_path(locale: :en)
    end
  end

  # Changing your email re-sends the confirmation.
  # Admin#clear_verified_at_if_email_changed only clears verified_at; without
  # this the new address would never get anything to confirm it with.
  class ResendVerificationOnEmailChangeTests < ActionDispatch::IntegrationTest
    test "sudo changing an admin's email re-sends the verification mail" do
      sign_in_as admins(:sudo)
      admin = admins(:one)

      assert_enqueued_email_with AdminMailer, :email_verification, params: { admin: admin, locale: :en } do
        patch admin_url(admin, locale: :en), params: { admin: { email_address: "changed@example.com" } }
      end
    end

    test "saving without changing the email sends nothing" do
      sign_in_as admins(:sudo)
      admin = admins(:one)

      assert_no_enqueued_emails do
        patch admin_url(admin, locale: :en), params: { admin: { username: admin.username } }
      end
    end

    # A full-access admin cannot change a coadmin's email at all — set_admin
    # refuses before this action's own logic runs, so nothing is enqueued.
    test "a full-access admin can no longer change a coadmin's email, so nothing is sent" do
      inviter = admins(:one)
      coadmin = admins(:upload_only)
      sign_in_as inviter

      assert_no_enqueued_emails do
        patch admin_url(coadmin, locale: :en), params: { admin: { email_address: "coadmin_changed@example.com" } }
      end
    end
  end

  # Privilege escalation via update. destroy asked can_manage?; update did not —
  # and can_manage? is false when the target is an OWNER, so a full-access admin
  # could reach an admin they managed whom sudo later promoted, while
  # coadmin_params permits :password and :email_address.
  #
  # Confirmed exploitable before the guard: the password digest changed, the
  # email was redirected, and the owner account then authenticated with the
  # attacker's chosen password.
  class UpdateEscalationTests < ActionDispatch::IntegrationTest
    test "a full-access admin cannot update an admin who has since become an owner" do
      inviter = admins(:one)
      victim  = admins(:read_only)          # read_only on personal, one's entity
      victim.update_column(:sudo, true)     # sudo promotes them later
      before = victim.reload.password_digest

      sign_in_as(inviter)
      patch admin_url(victim, locale: :en), params: {
        admin: { password: "takenover99", password_confirmation: "takenover99",
                 email_address: "attacker@example.com" }
      }

      victim.reload
      assert_equal before, victim.password_digest, "an owner's password was reset by their inviter"
      assert_not_equal "attacker@example.com", victim.email_address, "an owner's email was redirected"
      assert_not victim.authenticate("takenover99"), "the attacker can sign in as the owner"
    end

    # A full-access admin editing an ordinary coadmin's own fields was the
    # legitimate case the guard had to keep working. That action is gone
    # entirely — a claimed coadmin owns their own identity fields — so the only
    # thing left to assert is that it stays refused.
    test "a full-access admin can no longer update an ordinary coadmin's fields at all" do
      inviter = admins(:one)
      coadmin = admins(:upload_only)        # upload_receipts on personal, not an owner
      before = coadmin.email_address
      sign_in_as(inviter)

      patch admin_url(coadmin, locale: :en), params: { admin: { email_address: "legit@example.com" } }

      assert_redirected_to dashboard_path
      assert_equal before, coadmin.reload.email_address
    end

    # can_manage?(self) is false by design, so self-editing needs its own
    # clause — without it this guard would break every admin's own profile.
    test "an admin can still update their own record" do
      me = admins(:one)
      sign_in_as(me)

      patch admin_url(me, locale: :en), params: { admin: { email_address: "myself@example.com" } }

      assert_equal "myself@example.com", me.reload.email_address
    end

    # Sharing a different entity used to be enough to update a coadmin's own
    # fields. Now nothing is, for anyone but sudo and the coadmin themselves.
    test "sharing a different entity no longer lets a full-access admin update this coadmin" do
      shared = admins(:shared_reader) # personal (one's), but two holds family_biz
      before = shared.email_address
      sign_in_as(admins(:two))

      patch admin_url(shared, locale: :en), params: { admin: { email_address: "via-two@example.com" } }

      assert_redirected_to dashboard_path
      assert_equal before, shared.reload.email_address
    end

    # A coadmin who has since been given full_access ANYWHERE is a peer, not a
    # coadmin, and is no longer manageable by whoever used to manage them.
    test "a full-access admin can no longer update a coadmin who has become full access" do
      inviter = admins(:one)
      coadmin = admins(:upload_only)
      AdminEntity.where(admin: coadmin).update_all(access_level: 0) # now full_access
      before = coadmin.reload.email_address

      sign_in_as(inviter)
      patch admin_url(coadmin, locale: :en), params: { admin: { email_address: "nowfull@example.com" } }

      assert_equal before, coadmin.reload.email_address, "a full-access peer was still editable by a former manager"
    end

    # Owners are immune from every OTHER owner, not just from non-sudo inviters
    # — otherwise one owner could demote-then-delete another. can_manage?
    # already refused deleting an owner outright, but update had no such refusal
    # for the sudo branch.
    test "sudo can no longer update another owner" do
      other = admins(:one)
      other.update_column(:sudo, true)
      before = other.reload.email_address
      sign_in_as(admins(:sudo))

      patch admin_url(other, locale: :en), params: { admin: { email_address: "sudo-set@example.com" } }

      assert_equal before, other.reload.email_address, "one owner updated another owner"
    end

    # The one self-exception: an owner may still edit — and, per can_manage?,
    # delete — themselves. Demoting themselves is how a lone rogue-owner
    # situation resolves without touching anyone else's account.
    test "sudo can still update themselves, including unticking their own owner flag" do
      me = admins(:sudo)
      admins(:one).update_column(:sudo, true) # a second owner, so demotion is legal
      sign_in_as(me)

      patch admin_url(me, locale: :en), params: { admin: { sudo: "0" } }

      assert_not me.reload.sudo?
    end
  end

  # Promotion to owner clears entity links. An owner sees and writes every
  # entity regardless of any link, and is never a coadmin, so the moment sudo
  # ticks Owner the promoted admin's old links are stale and are cleared.
  class PromotionTests < ActionDispatch::IntegrationTest
    # admins(:one) holds personal, shared with other admins, and spouse, where
    # fixture one_spouse is the ONLY admin_entity — so promoting them orphans
    # spouse specifically, while personal keeps its other bookkeepers.
    test "promoting a full-access admin clears their entities, and orphans an entity they alone held" do
      promoted = admins(:one)
      spouse = entities(:spouse)
      assert_not spouse.orphaned?
      sign_in_as(admins(:sudo))

      patch admin_url(promoted, locale: :en), params: { admin: { sudo: "1" } }

      promoted.reload
      assert promoted.sudo?
      assert_empty promoted.admin_entities, "an owner still held entity links"
      assert spouse.reload.orphaned?, "the entity only this admin bookkept was not orphaned"
      assert_not_nil flash[:alert], "no warning was shown about the orphaned entity"
    end

    test "promoting an admin whose entities are all shared with someone else orphans nothing" do
      promoted = admins(:read_only) # personal only, shared with one/upload_only/mixed
      sign_in_as(admins(:sudo))

      patch admin_url(promoted, locale: :en), params: { admin: { sudo: "1" } }

      assert_empty promoted.reload.admin_entities
      assert_not entities(:personal).reload.orphaned?
      assert_nil flash[:alert]
    end
  end
end
