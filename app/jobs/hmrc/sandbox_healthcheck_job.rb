# frozen_string_literal: true

module Hmrc
  # Weekly automated exercise of the HMRC SANDBOX — an HMRC development-practice
  # expectation and our early-warning for breaking API changes. Mints a sandbox
  # application token and validates our fraud prevention headers against HMRC's
  # Test FPH API. Always targets sandbox, even after production go-live (the
  # validator only exists there — see Hmrc::FphValidator).
  #
  # Silent on success; on failure it retries, then alerts the sudo admin so
  # nobody has to watch it. Mirrors FetchExchangeRatesJob.
  class SandboxHealthcheckJob < ApplicationJob
    queue_as :default

    class HealthcheckError < StandardError; end

    retry_on HealthcheckError, wait: 1.hour, attempts: 3

    after_discard do |job, error|
      AdminMailer.with(error: error.message).hmrc_sandbox_check_failed.deliver_later
    end

    def perform
      return unless Config.sandbox_configured?

      result = FphValidator.run

      unless result.valid?
        detail = result.errors.map { |e| "#{Array(e['headers']).join(', ')} — #{e['message']}" }.join("; ")
        raise HealthcheckError,
              "HMRC sandbox FPH validation returned #{result.code} (HTTP #{result.http_code}). #{detail}".strip
      end

      Rails.logger.info "HMRC sandbox healthcheck: #{result.code} (HTTP #{result.http_code}) — OK"
    rescue HealthcheckError
      raise
    rescue => e
      # OAuth/network/parse failure — treat as a healthcheck failure so it
      # retries and, if it keeps failing, alerts.
      raise HealthcheckError, "HMRC sandbox healthcheck errored: #{e.class}: #{e.message}"
    end
  end
end
