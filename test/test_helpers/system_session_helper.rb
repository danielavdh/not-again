# Signing in for system tests.
#
# The browser is handed a session rather than driven through the login form. The
# value is produced by Rails' own cookie jar rather than by reimplementing the
# signing, which keeps it correct across Rails versions: if the app can read the
# cookie, this can write it.
#
# Now that there is ONE host, this could be replaced by driving the real login
# form. A worthwhile simplification, not done yet.
module SystemSessionHelper
  # Plain localhost. The `.test` host existed only because the session cookie
  # needed domain: :all across two hosts; with one host there is nothing to
  # share and no /etc/hosts entry to keep in step between this machine and CI.
  #
  # localhost is exempt from Chrome's HTTPS upgrade for the same reason `.test`
  # was — a PUBLIC domain would have form POSTs retried over TLS against a
  # plain-HTTP Puma.
  ACC_HOST = "localhost".freeze

  def sign_in_system(admin)
    session = admin.sessions.create!(user_agent: "system test", ip_address: "127.0.0.1")

    # A page must be open before a cookie can be set for its domain.
    visit app_url("/")
    page.driver.browser.manage.add_cookie(
      name:   "session_id",
      value:  signed_cookie_value(session.id),
      domain: ACC_HOST,
      path:   "/"
    )
    session
  end

  def app_url(path)
    "http://#{ACC_HOST}:#{Capybara.current_session.server.port}#{path}"
  end

  private

  # Rails' own signing, via a throwaway request. `jar["session_id"]` gives back
  # the signed string exactly as Set-Cookie would carry it.
  def signed_cookie_value(id)
    request = ActionDispatch::Request.new(
      Rails.application.env_config.merge(
        "HTTP_HOST"     => ACC_HOST,
        "rack.input"    => StringIO.new,
        "REQUEST_METHOD" => "GET"
      )
    )
    jar = ActionDispatch::Cookies::CookieJar.build(request, {})
    jar.signed[:session_id] = id
    jar["session_id"]
  end
end
