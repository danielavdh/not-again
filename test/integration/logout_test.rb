require "test_helper"

# Logging out, from either host, and the CSRF protection that used to be
# switched off to make it work.
#
# The accounts menu posted its logout to the MAIN host, and Rails refuses a
# state-changing request whose Origin is not the host that served the page — so
# `skip_forgery_protection only: :destroy` was added to get around it, which
# made logout CSRF-exempt for the whole application and let any site force a
# signed-in person to log out. /session answers on both hosts, so the menu posts
# locally and the exemption is gone.
#
# The suite runs with allow_forgery_protection = false, so this class of bug is
# invisible everywhere else. These tests turn it back on for their own duration
# and put it back afterwards — never leave it on, or unrelated tests start
# failing in confusing ways.
class LogoutTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:one)
  end

  def with_forgery_protection
    was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = was
  end

  # The token and the form Rails actually rendered, so the request looks like a
  # real browser's rather than a hand-built one.
  def logout_token_from(path)
    get path
    assert_response :success
    css_select("form[action*='/session'] input[name='authenticity_token']").first&.[]("value")
  end

  test "logging out works with CSRF protection on" do
    # Sign in FIRST: logging in is itself a POST, and with protection switched
    # on
    # it would be refused long before we got anywhere near logging out.
    sign_in_as(@admin)

    with_forgery_protection do
      # The GET has to be in here too: Rails only embeds an authenticity token
      # in
      # a form when protection is switched on.
      token = logout_token_from(dashboard_path(locale: :en))
      assert token.present?, "no logout form on the accounts dashboard"

      delete session_path(locale: :en),
             params: { authenticity_token: token },
             headers: { "HTTP_ORIGIN" => "http://www.example.com" }

      assert_response :see_other
      assert_equal root_url(locale: :en), response.location,
        "logout should land on the front page"
    end
  end

  test "a logout posted from another site is refused" do
    sign_in_as(@admin)

    with_forgery_protection do
      token = logout_token_from(dashboard_path(locale: :en))

      delete session_path(locale: :en),
             params: { authenticity_token: token },
             headers: { "HTTP_ORIGIN" => "https://evil.example.org" }

      # ApplicationController rescues InvalidAuthenticityToken and sends you to
      # the login page — the request is refused either way.
      assert_response :redirect
      assert_no_match %r{/session/new}, root_url,
        "sanity: the main root is not the login page"
      assert_match %r{/session/new}, response.location,
        "a cross-origin logout should be refused, not honoured"
    end
  end

  # --- what actually gets cleared -----------------------------------------

  test "logging out destroys the session row" do
    sign_in_as(@admin)
    assert_difference("Session.count", -1) do
      delete session_path(locale: :en)
    end
  end

  test "logging out empties the cookie session, not just a few keys of it" do
    sign_in_as(@admin)

    # Put something in the cookie session the old logout did not clear. The
    # login itself sets default_currency; filing_oauth_state is the one that
    # mattered — it is an OAuth CSRF token.
    get dashboard_path(locale: :en)
    assert session[:default_currency].present?, "login should have worked out a currency"

    delete session_path(locale: :en)

    assert_nil session[:default_currency]
    assert_nil session[:login_type]
    assert_nil session[:otp_verified]
    assert_nil session[:filing_oauth_state]
  end

  test "after logging out, the accounts side is closed again" do
    sign_in_as(@admin)
    delete session_path(locale: :en)

    get dashboard_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
  end
end
