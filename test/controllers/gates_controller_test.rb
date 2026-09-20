# frozen_string_literal: true
require "test_helper"

class GatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:two)
    @admin.update_columns(otp_secret: nil, otp_enabled: false)
    sign_in_as(@admin)
  end

  # --- Show ---

  test "show renders setup page when no otp_secret" do
    get otp_url(locale: :en)
    assert_response :success
  end

  test "show renders verify page when otp_secret present" do
    secret = ROTP::Base32.random
    @admin.update_columns(otp_secret: secret, otp_enabled: true)
    get otp_url(locale: :en)
    assert_response :success
  ensure
    @admin.update_columns(otp_secret: nil, otp_enabled: false)
  end

  # --- Verify ---

  test "verify with valid code redirects to root" do
    secret = ROTP::Base32.random
    @admin.update_columns(otp_secret: secret, otp_enabled: true)
    valid_code = ROTP::TOTP.new(secret, issuer: "Accounts").now
    post verify_otp_url(locale: :en), params: { otp_code: valid_code }
    assert_redirected_to dashboard_path
  ensure
    @admin.update_columns(otp_secret: nil, otp_enabled: false)
  end

  test "verify with invalid code returns unprocessable_entity" do
    secret = ROTP::Base32.random
    @admin.update_columns(otp_secret: secret, otp_enabled: true)
    post verify_otp_url(locale: :en), params: { otp_code: "000000" }
    assert_response :unprocessable_entity
  ensure
    @admin.update_columns(otp_secret: nil, otp_enabled: false)
  end

  # --- Confirm (setup) ---

  test "confirm with valid code enables otp and redirects" do
    secret = ROTP::Base32.random
    valid_code = ROTP::TOTP.new(secret, issuer: "Accounts").now
    post confirm_otp_url(locale: :en), params: { otp_secret: secret, otp_code: valid_code }
    assert_redirected_to dashboard_path
    @admin.reload
    assert @admin.otp_enabled
    assert_equal secret, @admin.otp_secret
  ensure
    @admin.update_columns(otp_secret: nil, otp_enabled: false)
  end

  test "confirm with invalid code returns unprocessable_entity" do
    secret = ROTP::Base32.random
    post confirm_otp_url(locale: :en), params: { otp_secret: secret, otp_code: "000000" }
    assert_response :unprocessable_entity
  end

  # The forced confirm-email-then-set-a-password sequence a draft coadmin goes
  # through at their first login. See Admin#draft?/#claim!, and
  # AdminsController::DraftClaimTests for the granting admin's side.
  class ClaimTests < ActionDispatch::IntegrationTest
    setup do
      granter = admins(:one) # full_access on personal
      sign_in_as(granter)
      post admins_url(locale: :en), params: {
        admin: { username: "claim_draft", password: "grantergiven1",
                 password_confirmation: "grantergiven1", email_address: "claim_draft@example.com" },
        access_level: "read_only",
        entity_ids: [ entities(:personal).id ]
      }
      @draft = Admin.find_by(username: "claim_draft")
      sign_out
    end

    test "an unverified draft is redirected to check their email, not the password form" do
      sign_in_as(@draft, password: "grantergiven1")
      get claim_url(locale: :en)
      assert_response :success
      assert_no_match(/password/i, response.body.scan(/name="password"/).join)
    end

    test "a draft cannot reach the dashboard before claiming" do
      sign_in_as(@draft, password: "grantergiven1")
      get dashboard_url(locale: :en)
      assert_redirected_to claim_path
    end

    test "claim_update refuses to set a password before the email is verified" do
      sign_in_as(@draft, password: "grantergiven1")
      patch claim_url(locale: :en), params: { password: "newpassword1", password_confirmation: "newpassword1" }
      assert_redirected_to claim_path
      assert @draft.reload.draft?
      assert @draft.authenticate("grantergiven1"), "the granter-chosen password must still work"
    end

    test "the full lifecycle: verify email, then set a password, then claimed? is true and old password is gone" do
      sign_in_as(@draft, password: "grantergiven1")
      token = @draft.generate_token_for(:email_verification)
      get verify_email_url(token: token, locale: :en)
      assert @draft.reload.verified?

      get claim_url(locale: :en)
      assert_response :success

      patch claim_url(locale: :en), params: { password: "mysecretnewpass1", password_confirmation: "mysecretnewpass1" }
      assert_redirected_to dashboard_path
      @draft.reload
      assert_not @draft.draft?
      assert @draft.claimed_at.present?
      assert_not @draft.authenticate("grantergiven1")
      assert @draft.authenticate("mysecretnewpass1")
    end

    test "claim_resend re-delivers the verification email to the signed-in draft" do
      sign_in_as(@draft, password: "grantergiven1")
      assert_enqueued_email_with AdminMailer, :email_verification, params: { admin: @draft, locale: :en } do
        post resend_claim_url(locale: :en)
      end
    end

    test "return_to_after_claim sends a freshly claimed admin back to where they were headed" do
      @draft.update!(terms_agreed_version: Admin::TERMS_VERSION, terms_agreed_at: Time.current)
      sign_in_as(@draft, password: "grantergiven1")
      token = @draft.generate_token_for(:email_verification)
      get verify_email_url(token: token, locale: :en)

      get admin_url(@draft, locale: :en) # any ordinary page, not dashboard
      assert_redirected_to claim_path

      patch claim_url(locale: :en), params: { password: "mysecretnewpass1", password_confirmation: "mysecretnewpass1" }
      assert_redirected_to admin_url(@draft, locale: :en)
    end

    test "a claimed admin visiting /claim directly is bounced to the dashboard, not shown the form again" do
      @draft.claim!
      sign_in_as(@draft, password: "grantergiven1")
      get claim_url(locale: :en)
      assert_redirected_to dashboard_path
    end
  end
end
