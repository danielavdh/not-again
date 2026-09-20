# frozen_string_literal: true

require "test_helper"

# What the trail is FOR: telling an operator that someone is trying to get in.
class SignInTrailTest < ActionDispatch::IntegrationTest
  setup { @admin = admins(:one) }

  test "a successful sign-in is recorded against the admin" do
    assert_difference("SignInEvent.count", 1) do
      post session_url(locale: :en), params: { username: @admin.username, password: "password" }
    end

    event = SignInEvent.last
    assert event.signed_in?
    assert_equal @admin.id, event.admin_id
    assert_equal @admin.username, event.username_attempted
    assert event.ip_address.present?, "no IP recorded"
  end

  test "a wrong password is recorded against the admin who owns the username" do
    assert_difference("SignInEvent.count", 1) do
      post session_url(locale: :en), params: { username: @admin.username, password: "wrong" }
    end

    assert SignInEvent.last.failed?
    assert_equal @admin.username, SignInEvent.last.username_attempted
  end

  # The entry that could not exist if this were a column on admins.
  test "an attempt on a username nobody has is recorded with no admin" do
    assert_difference("SignInEvent.count", 1) do
      post session_url(locale: :en), params: { username: "root", password: "hunter2" }
    end

    assert_nil SignInEvent.last.admin_id
    assert_equal "root", SignInEvent.last.username_attempted
  end

  # ⚠️ The reply must not tell an attacker which usernames are real. The table
  # knows the difference; the page must not show it.
  test "the refusal looks identical whether or not the username exists" do
    post session_url(locale: :en), params: { username: @admin.username, password: "wrong" }
    real_status, real_flash = response.status, flash[:alert]

    post session_url(locale: :en), params: { username: "nobody-at-all", password: "wrong" }

    assert_equal real_status, response.status
    assert_equal real_flash, flash[:alert], "the refusal reveals whether the username exists"
  end

  test "the password itself is never stored" do
    post session_url(locale: :en), params: { username: @admin.username, password: "sup3rs3cret" }

    assert_not_includes SignInEvent.last.attributes.values.map(&:to_s).join(" "), "sup3rs3cret"
  end

  # A logging table must never be able to refuse a legitimate login.
  test "a broken trail does not stop anyone signing in" do
    assert_difference("Session.count", 1, "a broken log refused a valid sign-in") do
      SignInEvent.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, "disk full" }) do
        post session_url(locale: :en), params: { username: @admin.username, password: "password" }
      end
    end

    assert_response :redirect
    assert_nil flash[:alert]
  end
  # THE ENTRY THE TABLE EXISTS FOR. A wrong password is someone guessing. A
  # RIGHT password stopped only by the second factor is someone who already
  # holds a working password — a different kind of news, and the one that should
  # get somebody out of bed.
  test "a failed second factor on a correct password is recorded as its own thing" do
    @admin.update!(otp_secret: ROTP::Base32.random, otp_enabled: true)
    post session_url(locale: :en), params: { username: @admin.username, password: "password" }

    assert_difference("SignInEvent.where(outcome: :otp_failed).count", 1) do
      post verify_otp_url(locale: :en), params: { otp_code: "000000" }
    end

    event = SignInEvent.last
    assert event.otp_failed?, "recorded as a plain failure — the distinction is the whole point"
    assert_equal @admin.id, event.admin_id
  end

  # If a correct code were logged as a failure the weekly report would cry wolf
  # every week, and the alarm would be turned off.
  test "a correct second factor is not recorded as a failure" do
    secret = ROTP::Base32.random
    @admin.update!(otp_secret: secret, otp_enabled: true)
    post session_url(locale: :en), params: { username: @admin.username, password: "password" }

    assert_no_difference("SignInEvent.where(outcome: :otp_failed).count") do
      post verify_otp_url(locale: :en), params: { otp_code: ROTP::TOTP.new(secret).now }
    end
  end
end
