# frozen_string_literal: true

require "net/http"
require "securerandom"

module Hmrc
  # Validates our fraud prevention headers against HMRC's Test Fraud Prevention
  # Headers API. That validator ONLY exists in the sandbox, so this always
  # targets sandbox explicitly, independent of the production flag. It is the
  # ongoing early warning that HMRC has not changed the header spec under us.
  class FphValidator
    Result = Struct.new(:http_code, :code, :message, :errors, :warnings, keyword_init: true) do
      def valid?
        code == "VALID_HEADERS"
      end

      def summary
        ["HTTP #{http_code}", "Result: #{code}", message].compact.join("   ")
      end
    end

    # Mints a sandbox application token and scores our representative headers.
    # Returns a Result; raises on OAuth or network failure, leaving the caller
    # to decide how to surface that.
    def self.run
      token   = Oauth.application_token(sandbox: true)
      headers = representative_headers

      uri  = URI("#{Config::SANDBOX_API_BASE}/test/fraud-prevention-headers/validate")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = 10
      http.read_timeout = 20

      req = Net::HTTP::Get.new(uri.request_uri)
      req["Authorization"] = "Bearer #{token}"
      req["Accept"]        = "application/vnd.hmrc.1.0+json"
      headers.each { |k, v| req[k] = v }

      res  = http.request(req)
      body = JSON.parse(res.body) rescue { "raw" => res.body }

      Result.new(
        http_code: res.code,
        code:      body["code"],
        message:   body["message"],
        errors:    Array(body["errors"]),
        warnings:  Array(body["warnings"])
      )
    end

    # Representative request context — no live HTTP request exists in a rake
    # task or a background job. On the server the outbound IP is the vendor IP,
    # so the vendor headers reflect reality; the live app sends the real
    # navigator.userAgent and browser values on user-facing calls.
    def self.representative_headers
      fake_request = Struct.new(:remote_ip, :env).new("198.51.100.1", { "REMOTE_PORT" => "56789" })
      admin        = Struct.new(:id).new(1)
      browser = {
        device_id:   SecureRandom.uuid,
        user_agent:  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
                     "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        timezone:    "UTC+01:00",
        screens:     "width=1920&height=1080&scaling-factor=1&colour-depth=24",
        window_size: "width=1280&height=800"
      }
      Hmrc::FraudPreventionHeaders.new(
        request: fake_request, admin: admin, browser: browser, mfa_at: Time.now.to_i
      ).to_h
    end
  end
end
