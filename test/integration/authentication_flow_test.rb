require "test_helper"

# Admins are the only people who log in here.
class AuthenticationFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = admins(:one)
    ActionMailer::Base.deliveries.clear
  end

  # The locale has to survive the round trip through the email, because the link
  # in it is the only way back into the flow.
  test "language: spanish persists throughout the password reset flow" do
    get new_password_path(locale: "es")
    assert_response :success

    perform_enqueued_jobs do
      post passwords_path(locale: "es"), params: { email_address: @admin.email_address }
    end
    assert_redirected_to new_session_path(locale: "es")

    mail = ActionMailer::Base.deliveries.last
    assert_match "/es/passwords/", mail.body.encoded

    token = @admin.generate_token_for(:password_reset)
    get edit_password_path(token: token, locale: "es")
    assert_response :success
    assert_select "form[action*='/es/passwords']"

    put password_path(token: token, locale: "es"),
        params: { password: "newpassword", password_confirmation: "newpassword" }
    assert_redirected_to new_session_path(locale: "es")
  end

  test "admin password reset flow (happy path)" do
    get login_path
    get new_password_path

    perform_enqueued_jobs do
      post passwords_path, params: { email_address: @admin.email_address }
    end

    assert_redirected_to new_session_path(locale: "en")
    follow_redirect!
    assert_select "input[name=username]"

    token = @admin.generate_token_for(:password_reset)
    put password_path(token: token),
        params: { password: "newpassword123", password_confirmation: "newpassword123" }

    assert_redirected_to new_session_path(locale: "en")
    follow_redirect!
    assert_select "input[name=username]"
  end
end
