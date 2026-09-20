# frozen_string_literal: true

require "test_helper"
require "aws-sdk-s3"

class MaintenanceReportJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  # The job's entire purpose is that a mail leaves the building every week. If
  # it runs and enqueues nothing, the dead-man's-switch is dead and the silence
  # reads as good news.
  #
  # Asserts the mail is actually DELIVERED, not merely enqueued: an enqueued
  # assertion passed while the delivery raised SerializationError on every real
  # run — Findings are Structs, which ActiveJob cannot serialise — so the report
  # would never once have been sent.
  test "running the job sends the report" do
    assert_emails 1 do
      MaintenanceReportJob.perform_now
    end
  end

  # No retry_on and no after_discard, deliberately, unlike every other scheduled
  # job here. Those all end in "email sudo on failure", which is circular for
  # the job that sends that email — and a retry would mean the Monday report
  # arriving on Tuesday, blunting the one signal it provides.
  test "the report job does not fall back to emailing about itself" do
    assert_empty MaintenanceReportJob.rescue_handlers,
      "a retry/discard handler here would make the report depend on the mail path it is testing"
  end
end
