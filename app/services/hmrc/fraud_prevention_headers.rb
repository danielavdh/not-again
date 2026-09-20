# frozen_string_literal: true

require "erb"
require "digest"

module Hmrc
  # HMRC's mandatory fraud prevention headers for the "web application via
  # server" connection method. A legal requirement on every MTD ITSA API call,
  # and verified by HMRC before production access is granted.
  #
  # SCOPED TO HMRC: only Hmrc::Client attaches these. No other authority's
  # client may send them.
  #
  # Spec and exact value formats:
  # https://developer.service.hmrc.gov.uk/guides/fraud-prevention/connection-
  # method/web-app-via-server/
  #
  # `browser` carries the values collected client-side (HmrcFraudPrevention in
  # tax.js), symbol-keyed: :device_id, :user_agent, :screens, :window_size,
  # :timezone. Anything unavailable is dropped rather than sent blank.
  class FraudPreventionHeaders
    CONNECTION_METHOD = "WEB_APP_VIA_SERVER"
    # HMRC key namespacing our own identifiers in the *=value headers.
    #
    # CONFIGURABLE for the same reason as Config::PRODUCT_NAME: this identifies
    # the VENDOR, so a self-hoster sending this repo's default would be
    # reporting somebody else's identity to HMRC.
    VENDOR_KEY = (
      Rails.application.credentials.dig(:hmrc, :vendor, :key) ||
      ENV["HMRC_VENDOR_KEY"].presence ||
      "not-again"
    ).freeze

    # mfa_at: unix timestamp (Integer) of the admin's TOTP verification, from
    # session[:otp_verified]["at"]. Omitted when absent (never fabricated).
    def initialize(request:, admin: nil, browser: {}, mfa_at: nil)
      @request = request
      @admin   = admin
      @browser = (browser || {}).symbolize_keys
      @mfa_at  = mfa_at
    end

    def to_h
      {
        "Gov-Client-Connection-Method"      => CONNECTION_METHOD,
        "Gov-Client-Device-ID"              => @browser[:device_id],
        "Gov-Client-User-IDs"               => user_ids,
        "Gov-Client-Timezone"               => @browser[:timezone],
        "Gov-Client-Screens"                => @browser[:screens],
        "Gov-Client-Window-Size"            => @browser[:window_size],
        "Gov-Client-Browser-JS-User-Agent"  => @browser[:user_agent],
        "Gov-Client-Multi-Factor"           => multi_factor,
        "Gov-Client-Public-IP"              => client_ip,
        "Gov-Client-Public-IP-Timestamp"    => timestamp,
        "Gov-Client-Public-Port"            => client_port,
        "Gov-Vendor-Version"                => vendor_version,
        "Gov-Vendor-License-IDs"            => vendor_license_ids,
        "Gov-Vendor-Product-Name"           => vendor_product_name,
        "Gov-Vendor-Forwarded"              => vendor_forwarded,
        "Gov-Vendor-Public-IP"              => vendor_public_ip
      }.compact_blank
    end

    private

    # key=value, both percent-encoded, separators (= &) left raw.
    def kv(pairs)
      pairs.map { |k, v| "#{pct(k)}=#{pct(v)}" }.join("&")
    end

    def pct(value)
      ERB::Util.url_encode(value.to_s)
    end

    def user_ids
      return if @admin.nil?
      kv(VENDOR_KEY => @admin.id)
    end

    # Admins authenticate with a TOTP authenticator app. Reported only when the
    # verification time is known, so it is never fabricated. HMRC's timestamp
    # format is "yyyy-MM-ddThh:mmZ", percent-encoded in the value.
    def multi_factor
      return if @mfa_at.blank?
      ts  = Time.at(@mfa_at.to_i).utc.strftime("%Y-%m-%dT%H:%MZ")
      ref = Digest::SHA256.hexdigest("#{@admin&.id}:#{@mfa_at}")
      "type=TOTP&timestamp=#{pct(ts)}&unique-reference=#{pct(ref)}"
    end

    def client_ip
      @request&.remote_ip
    end

    # Source port of the client's connection. Often lost behind a reverse
    # proxy; sent only when actually present.
    def client_port
      port = @request&.env&.dig("REMOTE_PORT").presence
      port if port && port.to_i.between?(1, 65_535) && ![80, 443].include?(port.to_i)
    end

    def timestamp
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    def vendor_version
      kv(VENDOR_KEY => Config::SOFTWARE_VERSION)
    end

    def vendor_product_name
      pct(Config::PRODUCT_NAME)
    end

    # Self-hosted, so there is no third-party licence key by default. Sent only
    # if one is configured (credentials hmrc.vendor.license_id).
    def vendor_license_ids
      id = Config.vendor_license_id
      kv(VENDOR_KEY => id) if id.present?
    end

    # by = the public IP this server received the request on; for = the client.
    def vendor_forwarded
      return if vendor_public_ip.blank? || client_ip.blank?
      "by=#{pct(vendor_public_ip)}&for=#{pct(client_ip)}"
    end

    def vendor_public_ip
      Config.vendor_public_ip
    end
  end
end
