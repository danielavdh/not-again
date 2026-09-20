# frozen_string_literal: true

require "test_helper"

class Hmrc::FraudPreventionHeadersTest < ActiveSupport::TestCase
  FakeRequest = Struct.new(:remote_ip, :env)

  def build(browser: {}, admin: admin_stub, remote_ip: "198.51.100.1", env: { "REMOTE_PORT" => "54321" })
    Hmrc::FraudPreventionHeaders.new(
      request: FakeRequest.new(remote_ip, env),
      admin:   admin,
      browser: browser
    ).to_h
  end

  def admin_stub
    Struct.new(:id).new(67)
  end

  def with_vendor_ip(ip, &block)
    Hmrc::Config.stub(:vendor_public_ip, ip, &block)
  end

  test "builds the mandatory web-app-via-server headers in HMRC's formats" do
    browser = {
      device_id:   "beec798b-b366-47fa-b1f8-92cede14a1ce",
      user_agent:  "Mozilla/5.0 (X11)",
      timezone:    "UTC+01:00",
      screens:     "width=1920&height=1080&scaling-factor=1&colour-depth=24",
      window_size: "width=800&height=600"
    }

    key = Hmrc::FraudPreventionHeaders::VENDOR_KEY
    h   = with_vendor_ip("203.0.113.6") { build(browser: browser) }

    assert_equal "WEB_APP_VIA_SERVER", h["Gov-Client-Connection-Method"]
    assert_equal "beec798b-b366-47fa-b1f8-92cede14a1ce", h["Gov-Client-Device-ID"]
    assert_equal "Mozilla/5.0 (X11)", h["Gov-Client-Browser-JS-User-Agent"]
    assert_equal "UTC+01:00", h["Gov-Client-Timezone"]
    assert_equal "width=1920&height=1080&scaling-factor=1&colour-depth=24", h["Gov-Client-Screens"]
    assert_equal "width=800&height=600", h["Gov-Client-Window-Size"]
    # The vendor key is CONFIGURATION now, so assert the shape it produces
    # rather than one installation's value.
    assert_equal "#{key}=67", h["Gov-Client-User-IDs"]
    assert_equal "198.51.100.1", h["Gov-Client-Public-IP"]
    assert_equal "54321", h["Gov-Client-Public-Port"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, h["Gov-Client-Public-IP-Timestamp"])
    assert_equal "#{key}=#{Hmrc::Config::SOFTWARE_VERSION}", h["Gov-Vendor-Version"]
    # Percent-encoding IS the behaviour under test — a raw space would make
    # the header invalid.
    assert_equal Hmrc::Config::PRODUCT_NAME.gsub(" ", "%20"), h["Gov-Vendor-Product-Name"]
    assert_no_match(/ /, h["Gov-Vendor-Product-Name"])
    assert_equal "203.0.113.6", h["Gov-Vendor-Public-IP"]
    assert_equal "by=203.0.113.6&for=198.51.100.1", h["Gov-Vendor-Forwarded"]
    assert_match(/\A#{Regexp.escape(key)}=[0-9a-f]{64}\z/, h["Gov-Vendor-License-IDs"])
  end

  test "reports TOTP multi-factor when the OTP verification time is known" do
    at = Time.utc(2026, 7, 10, 9, 5, 0).to_i
    h = Hmrc::FraudPreventionHeaders.new(
      request: FakeRequest.new("198.51.100.1", {}),
      admin:   admin_stub,
      mfa_at:  at
    ).to_h

    ref = Digest::SHA256.hexdigest("67:#{at}")
    assert_equal "type=TOTP&timestamp=2026-07-10T09%3A05Z&unique-reference=#{ref}",
                 h["Gov-Client-Multi-Factor"]
  end

  test "omits multi-factor when no OTP verification time is present" do
    refute build(browser: {}).key?("Gov-Client-Multi-Factor")
  end

  test "omits unavailable values rather than sending blanks" do
    h = with_vendor_ip(nil) { build(browser: {}, admin: nil, env: {}) }

    assert_equal "WEB_APP_VIA_SERVER", h["Gov-Client-Connection-Method"]
    refute h.key?("Gov-Client-Device-ID")
    refute h.key?("Gov-Client-User-IDs")
    refute h.key?("Gov-Client-Public-Port")
    refute h.key?("Gov-Vendor-Forwarded") # no vendor IP → no "by=" to build
  end

  test "rejects server ports for Gov-Client-Public-Port" do
    assert_nil build(env: { "REMOTE_PORT" => "443" })["Gov-Client-Public-Port"]
  end
end
