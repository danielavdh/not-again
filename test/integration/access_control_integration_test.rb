# frozen_string_literal: true

require "test_helper"

class AccessControlIntegrationTest < ActionDispatch::IntegrationTest

  # ==================== Upload-Only Admin Restrictions ====================

  class UploadOnlyRestrictions < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:upload_only)
      sign_in_as(@admin)
    end

    test "redirected to upload_standalone on accounts index" do
      get accounts_url(locale: :en)
      assert_redirected_to upload_standalone_receipts_path
    end

    test "redirected to upload_standalone on journal_entries index" do
      get journal_entries_url(locale: :en)
      assert_redirected_to upload_standalone_receipts_path
    end

    test "can access upload_standalone" do
      get upload_standalone_receipts_url(locale: :en)
      assert_response :success
    end

    test "can create receipt via upload_standalone flow" do
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      assert_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "Upload Test",
            receipt_date: Date.current.to_s,
            entity_id: entities(:personal).id,
            scan: scan_file
          }
        }
      end
    end
  end

  # ==================== Read-Only Admin Restrictions ====================

  class ReadOnlyRestrictions < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:read_only)
      @entity = entities(:personal)
      sign_in_as(@admin)
    end

    test "can view accounts index" do
      get accounts_url(locale: :en)
      assert_response :success
    end

    test "can view account show" do
      account = accounts(:boss_bank)  # entity 01
      get account_url(account, locale: :en)
      assert_response :success
    end

    test "cannot access new account" do
      get new_account_url(locale: :en)
      assert_redirected_to dashboard_path
    end

    test "cannot create account" do
      assert_no_difference("Account.count") do
        post accounts_url(locale: :en), params: {
          account: { code: "101999", name: "Hack", account_type: :asset }
        }
      end
      assert_redirected_to dashboard_path
    end

    test "can view journal entries index" do
      get journal_entries_url(locale: :en)
      assert_response :success
    end

    test "cannot create journal entry" do
      assert_no_difference("JournalEntry.count") do
        post journal_entries_url(locale: :en), params: {
          journal_entry: {
            entry_date: Date.current,
            memo: "Hack"
          }
        }
      end
      assert_redirected_to dashboard_path
    end

    test "can view receipts index" do
      get receipts_url(locale: :en)
      assert_response :success
    end

    test "cannot upload receipt (no receipt access)" do
      get new_receipt_url(locale: :en)
      assert_response :redirect
    end
  end

  # ==================== Cross-Entity Access Tests ====================

  class CrossEntityAccess < ActionDispatch::IntegrationTest
    setup do
    end

    test "admin one cannot see admin two accounts" do
      sign_in_as(admins(:one))
      # admin one has entities 01, 03 — bank_gbp is entity 10
      get account_url(accounts(:bank_gbp), locale: :en)
      # find_accessible_account rescues RecordNotFound and redirects
      assert_response :redirect
    end

    test "admin two cannot see admin one accounts" do
      sign_in_as(admins(:two))
      # admin two has entities 10, 04 — boss_bank is entity 01
      get account_url(accounts(:boss_bank), locale: :en)
      assert_response :redirect
    end

    test "admin one cannot see admin two receipts" do
      sign_in_as(admins(:one))
      get receipt_url(receipts(:linked_receipt), locale: :en)  # entity 10
      assert_response :not_found
    end

    test "sudo can see all entities accounts" do
      sign_in_as(admins(:sudo))
      get account_url(accounts(:bank_gbp), locale: :en)
      assert_response :success
      get account_url(accounts(:boss_bank), locale: :en)
      assert_response :success
    end

    test "sudo can see all receipts" do
      sign_in_as(admins(:sudo))
      get receipt_url(receipts(:linked_receipt), locale: :en)
      assert_response :success
      get receipt_url(receipts(:personal_receipt), locale: :en)
      assert_response :success
    end
  end
end
