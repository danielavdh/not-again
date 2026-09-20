require "test_helper"

# The second factor is required in production only, so the whole suite runs with
# it switched off and the filter is never otherwise exercised. These tests turn
# it on for the duration of a request.
#
# The filter belongs to the admin session, not to one subdomain, so the main-
# site backend requires it too.
class OtpGateTest < ActionDispatch::IntegrationTest
  setup do
    @admin  = admins(:one)   # full_access on personal(01) + spouse(03)
    @secret = ROTP::Base32.random
    @admin.update!(otp_secret: @secret, otp_enabled: true)
  end

  def with_otp_required(&block)
    Admin.stub(:otp_required?, true, &block)
  end

  def current_code
    ROTP::TOTP.new(@secret, issuer: "Accounts").now
  end

  test "an unverified admin is challenged on the accounts subdomain" do
    with_otp_required do
      sign_in_as(@admin)
      get dashboard_path(locale: :en)
      assert_redirected_to otp_path(locale: :en)
    end
  end

  test "a wrong code does not open the gate" do
    with_otp_required do
      sign_in_as(@admin)
      post verify_otp_path(locale: :en), params: { otp_code: "000000" }
      assert_response :unprocessable_entity

      get dashboard_path(locale: :en)
      assert_redirected_to otp_path(locale: :en)
    end
  end

  # When the proof of the second factor runs out, the session goes with it. A
  # session that outlives its own proof stays valid and merely re-challenges, so
  # a cookie stolen after the window still needs a TOTP code and never the
  # password.
  test "a verification that has run out ends the session, not just the page" do
    with_otp_required do
      sign_in_as(@admin)
      post verify_otp_path(locale: :en), params: { otp_code: current_code }
      get dashboard_path(locale: :en)
      assert_response :success, "should be through the gate"

      travel 37.hours do
        get dashboard_path(locale: :en)
        assert_redirected_to new_session_path(locale: :en)
      end

      assert_not Session.exists?(admin: @admin),
                 "the session row outlived the second factor that authorised it"
    end
  end

  # The distinction the above rests on. `fresh` is false in two situations and
  # only one is an expiry: someone who has just signed in has never verified at
  # all, and evicting them there would log every admin out at the instant they
  # arrived, leaving nobody able to sign in.
  test "an admin who has not verified yet is challenged, not evicted" do
    with_otp_required do
      sign_in_as(@admin)
      get dashboard_path(locale: :en)
      assert_redirected_to otp_path(locale: :en)
      assert Session.exists?(admin: @admin), "signing in must not evict the session it just made"
    end
  end

  test "an admin with no secret yet is sent to set one up" do
    @admin.update!(otp_secret: nil, otp_enabled: false)
    with_otp_required do
      sign_in_as(@admin)
      get dashboard_path(locale: :en)
      assert_redirected_to otp_path(locale: :en)
      assert_equal I18n.t("access.setup_2fa"), flash[:alert]
    end
  end

  # Deliberate exemption: these are people who photograph a receipt and send it.
  # A TOTP app is beyond what can be asked of them, and the standalone uploader
  # is all they can reach.
  test "an upload-receipts co-admin is never challenged" do
    uploader = admins(:upload_only)
    with_otp_required do
      sign_in_as(uploader)
      get upload_standalone_receipts_path(locale: :en)
      assert_response :success
    end
  end


  # A brand-new admin has neither a second factor nor an agreement to the
  # current terms — the state every real installation starts in, straight after
  # `bin/rails install:owner`.
  #
  # BaseController runs the OTP gate BEFORE the terms gate, so /otp has to be
  # reachable without agreeing first. When it was not, /otp redirected to
  # /terms (terms gate), /terms redirected to /otp (OTP gate), and the browser
  # gave up: ERR_TOO_MANY_REDIRECTS, on the first login, for every new account
  # on a live server.
  #
  # Nothing caught it because Admin.otp_required? is Rails.env.production? —
  # the OTP gate never fires in test, so the loop cannot form. Hence
  # with_otp_required here.
  test "a new admin with no second factor and no agreed terms can still reach the OTP setup" do
    @admin.update!(otp_secret: nil, otp_enabled: false,
                   terms_agreed_version: nil, terms_agreed_at: nil)

    with_otp_required do
      post session_url(locale: :en),
           params: { username: @admin.username, password: "password" }

      get otp_path(locale: :en)
      assert_response :success,
        "the second-factor page must render — a redirect here is the login loop"
    end
  end

  # The other half of the same loop: the terms page must send an admin who has
  # no second factor to /otp, and /otp must then stop. One hop, not a volley.
  test "the terms page sends a new admin to the second factor, and it ends there" do
    @admin.update!(otp_secret: nil, otp_enabled: false,
                   terms_agreed_version: nil, terms_agreed_at: nil)

    with_otp_required do
      post session_url(locale: :en),
           params: { username: @admin.username, password: "password" }

      get terms_path(locale: :en)
      assert_redirected_to otp_path(locale: :en)

      follow_redirect!
      assert_response :success, "/otp bounced onwards — the gates are still circular"
    end
  end
end

# The return target is read back out of the session, so the OTP controller only
# follows one that belongs to us. Driven directly: the only way to get a foreign
# value in there is to tamper with a signed cookie, which an integration test
# cannot do without also destroying the login.
class OtpReturnTargetTest < ActionController::TestCase
  tests GatesController

  setup do
    @request.host = "accounts.example.com"
    @controller.request = @request
  end

  test "a URL on one of our hosts is followed" do
    target = "http://www.example.com/en/admin/users"
    @request.session[:return_to_after_otp] = target
    assert_equal target, @controller.send(:after_otp_url)
  end

  test "a foreign host is discarded" do
    @request.session[:return_to_after_otp] = "https://evil.example.org/steal"
    assert_equal dashboard_path, @controller.send(:after_otp_url)
  end

  test "a bare path is discarded — it would resolve against the wrong host" do
    @request.session[:return_to_after_otp] = "/en/admin/users"
    assert_equal dashboard_path, @controller.send(:after_otp_url)
  end

  test "an unparseable value is discarded" do
    @request.session[:return_to_after_otp] = "http://[bad"
    assert_equal dashboard_path, @controller.send(:after_otp_url)
  end

  test "no stored target lands on the accounts root" do
    assert_equal dashboard_path, @controller.send(:after_otp_url)
  end
end
