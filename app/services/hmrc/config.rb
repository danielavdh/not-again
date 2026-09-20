# frozen_string_literal: true

module Hmrc
  module Config
    SANDBOX    = Rails.application.credentials.dig(:hmrc, :production, :client_id).blank?
    SCOPES     = "read:self-assessment write:self-assessment".freeze

    # Fraud prevention header vendor identity. Product name is percent-encoded
    # at build time; bump SOFTWARE_VERSION on each release so HMRC sees an
    # accurate Gov-Vendor-Version.
    #
    # CONFIGURABLE, and it must match what HMRC has registered for YOUR
    # installation: two installations sending the same product name are
    # indistinguishable in HMRC's monitoring, so a self-hoster must set their
    # own rather than inherit whatever this repo ships.
    PRODUCT_NAME = (
      Rails.application.credentials.dig(:hmrc, :vendor, :product_name) ||
      ENV["HMRC_PRODUCT_NAME"].presence ||
      "not-again Accounts"
    ).freeze
    SOFTWARE_VERSION = "1.0.0".freeze

    # Server's own public IP for Gov-Vendor-Public-IP and the "by" of Gov-
    # Vendor-Forwarded. Not reliably self-discoverable behind a proxy, so
    # configured.
    def self.vendor_public_ip
      Rails.application.credentials.dig(:hmrc, :vendor, :public_ip) || ENV["HMRC_VENDOR_PUBLIC_IP"]
    end

    # Gov-Vendor-License-IDs is required even for self-hosted software, so this
    # falls back to a stable hashed identifier for the build when none is
    # configured.
    def self.vendor_license_id
      Rails.application.credentials.dig(:hmrc, :vendor, :license_id) ||
        Digest::SHA256.hexdigest("#{PRODUCT_NAME}-#{SOFTWARE_VERSION}")
    end

    API_BASE = if SANDBOX
      "https://test-api.service.hmrc.gov.uk"
    else
      "https://api.service.hmrc.gov.uk"
    end

    OAUTH_BASE = if SANDBOX
      "https://test-www.tax.service.gov.uk"
    else
      "https://www.tax.service.gov.uk"
    end

    def self.client_id
      env = SANDBOX ? :sandbox : :production
      Rails.application.credentials.dig(:hmrc, env, :client_id) ||
        raise("Missing credential: hmrc.#{env}.client_id")
    end

    def self.client_secret
      env = SANDBOX ? :sandbox : :production
      Rails.application.credentials.dig(:hmrc, env, :client_secret) ||
        raise("Missing credential: hmrc.#{env}.client_secret")
    end

    # Sandbox is always reachable, independent of the production flag: the
    # weekly healthcheck and the FPH validator must keep hitting sandbox even
    # after go-live, because the validator only exists there.
    SANDBOX_API_BASE = "https://test-api.service.hmrc.gov.uk".freeze

    def self.sandbox_configured?
      Rails.application.credentials.dig(:hmrc, :sandbox, :client_id).present?
    end

    def self.sandbox_client_id
      Rails.application.credentials.dig(:hmrc, :sandbox, :client_id) ||
        raise("Missing credential: hmrc.sandbox.client_id")
    end

    def self.sandbox_client_secret
      Rails.application.credentials.dig(:hmrc, :sandbox, :client_secret) ||
        raise("Missing credential: hmrc.sandbox.client_secret")
    end

    # The redirect URI in use comes from FilingController#filing_callback_uri,
    # which asks the connector for the path registered with its authority — not
    # from here.

    # The API field name for a category lives on the category row itself
    # (tax_categories.api_field, declared in db/tax_categories/*.yml), so there
    # is no second file that can silently omit one.
  end
end
