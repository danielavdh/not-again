# frozen_string_literal: true

require "test_helper"

module Hmrc
  class SandboxHealthcheckJobTest < ActiveJob::TestCase
    include ActionMailer::TestHelper

    def valid_result
      FphValidator::Result.new(http_code: "200", code: "VALID_HEADERS",
                               message: nil, errors: [], warnings: [])
    end

    def invalid_result
      FphValidator::Result.new(
        http_code: "200", code: "POTENTIALLY_INVALID_HEADERS", message: "problems",
        errors: [{ "headers" => ["Gov-Client-Timezone"], "message" => "invalid" }], warnings: []
      )
    end

    # perform is called bare (bypassing retry_on) so failures propagate
    # deterministically — no reliance on retry timing.

    test "does nothing when sandbox is not configured" do
      Config.stub(:sandbox_configured?, false) do
        FphValidator.stub(:run, ->(*) { raise "should not be called" }) do
          assert_nothing_raised { SandboxHealthcheckJob.new.perform }
        end
      end
    end

    test "stays silent when headers are valid" do
      Config.stub(:sandbox_configured?, true) do
        FphValidator.stub(:run, valid_result) do
          assert_nothing_raised { SandboxHealthcheckJob.new.perform }
        end
      end
    end

    test "raises HealthcheckError when validation is not VALID_HEADERS" do
      Config.stub(:sandbox_configured?, true) do
        FphValidator.stub(:run, invalid_result) do
          error = assert_raises(SandboxHealthcheckJob::HealthcheckError) { SandboxHealthcheckJob.new.perform }
          assert_match "POTENTIALLY_INVALID_HEADERS", error.message
        end
      end
    end

    test "wraps an OAuth/network error as a HealthcheckError" do
      Config.stub(:sandbox_configured?, true) do
        FphValidator.stub(:run, ->(*) { raise "connection refused" }) do
          error = assert_raises(SandboxHealthcheckJob::HealthcheckError) { SandboxHealthcheckJob.new.perform }
          assert_match "connection refused", error.message
        end
      end
    end

    # The after_discard → mailer wiring mirrors the proven
    # FetchExchangeRatesJob;
    # here we pin the alert's recipient and content (what actually matters).
    test "the failure alert goes to the sudo admin with the error detail" do
      admin = admins(:sudo)
      mail  = AdminMailer.with(admin: admin, error: "sandbox down").hmrc_sandbox_check_failed

      assert_equal [admin.email_address], mail.to
      assert_match "sandbox", mail.subject.downcase
      assert_match "sandbox down", mail.text_part.body.to_s
      assert_match "sandbox down", mail.html_part.body.to_s
    end
  end
end
