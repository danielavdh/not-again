require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @admin = admins(:one) }

  test "new" do
    get new_session_path(locale: :en)
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path(locale: :en), params: { username: @admin.username, password: "password" }

    # Full-access admins land on the dashboard, not their own profile page.
    assert_redirected_to dashboard_path(locale: :en)
    assert cookies[:session_id]
    # TODO: assert session[:default_currency] is set from the admin's accessible
    # balance accounts
    # (exercises the for_entity_codes scope in
    # set_default_currency_from_accounts)
  end

  test "create with invalid credentials" do
    post session_path(locale: :en), params: { username: @admin.username, password: "wrong" }

    assert_redirected_to new_session_path(locale: :en)
    assert_nil cookies[:session_id]
  end

  # It used to be a plain attribute assignment with no save, so the column kept
  # whatever before_create put there and never moved again.
  test "signing in records last_seen" do
    @admin.update_column(:last_seen, 3.years.ago)

    post session_path(locale: :en), params: { username: @admin.username, password: "password" }

    assert_operator @admin.reload.last_seen, :>, 1.minute.ago,
                   "last_seen must be written to the database on sign-in"
  end

  test "signing in does not count as editing the record" do
    was = @admin.updated_at
    post session_path(locale: :en), params: { username: @admin.username, password: "password" }
    assert_equal was.to_i, @admin.reload.updated_at.to_i,
                 "updated_at must not move — signing in is not a change to the record"
  end

  test "an admin with no entity access yet lands on their own profile, not the dashboard" do
    admin = Admin.create!(username: "pending_assignment", password: "password12",
                          email_address: "pending@example.com")

    post session_path(locale: :en), params: { username: admin.username, password: "password12" }

    assert_redirected_to admin_path(admin, locale: :en)
  end

  test "destroy" do
    sign_in_as(@admin)

    delete session_path(locale: :en)

    assert_redirected_to root_url(locale: :en)
    assert_empty cookies[:session_id]
  end
end