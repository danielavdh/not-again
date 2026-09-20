require "test_helper"

# Only admins have passwords here. This used to cover the main site's musicians
# and residents as well, which is why it once needed a users fixture.
class PasswordsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = admins(:one)
  end

  test "new" do
    get new_password_path(locale: :en)
    assert_response :success
  end

  test "create sends a password reset email for a known admin" do
    assert_enqueued_jobs 1 do
      post passwords_path(locale: :en), params: { email_address: @admin.email_address }
    end
    assert_redirected_to new_session_path(locale: :en)
  end

  # Same answer either way, or this page tells you which addresses have an
  # account.
  test "create for an unknown address redirects but sends no mail" do
    assert_emails 0 do
      perform_enqueued_jobs do
        post passwords_path(locale: :en), params: { email_address: "missing-admin@example.com" }
      end
    end
    assert_redirected_to new_session_path(locale: :en)
  end

  test "edit" do
    get edit_password_path(@admin.generate_token_for(:password_reset), locale: :en)
    assert_response :success
  end

  test "edit with invalid password reset token" do
    get edit_password_path("invalid token", locale: :en)
    assert_redirected_to new_password_path(locale: :en)
  end

  test "update" do
    token = @admin.generate_token_for(:password_reset)
    assert_changes -> { @admin.reload.password_digest } do
      put password_path(token, locale: :en), params: { password: "newpassword", password_confirmation: "newpassword" }
      assert_redirected_to new_session_path(locale: :en)
    end
  end

  test "update with non matching passwords" do
    token = @admin.generate_token_for(:password_reset)
    assert_no_changes -> { @admin.reload.password_digest } do
      put password_path(token, locale: :en), params: { password: "no", password_confirmation: "match" }
      assert_redirected_to edit_password_path(token, locale: :en)
    end
  end
end
