# frozen_string_literal: true

# Sends the weekly maintenance report to whoever runs this installation.
#
# Deliberately has NO retry_on and NO after_discard, unlike every other
# scheduled job here. The pattern elsewhere is "retry, then email sudo on
# failure", which cannot work for the job whose whole purpose is to send that
# email. If this one fails there is nothing left to tell anybody, and the
# missing Monday mail is the signal instead.
class MaintenanceReportJob < ApplicationJob
  queue_as :default

  def perform
    findings = Maintenance::WeeklyCheck.call

    # deliver_NOW. This is already a background job, so deliver_later would only
    # enqueue a second one — and it cannot work anyway: ActiveJob serialises
    # params, and a Finding is a Struct, so it raised SerializationError every
    # run. Nothing would have caught that but the report failing to arrive.
    AdminMailer.with(findings: findings).weekly_status.deliver_now

    problems = findings.reject(&:ok)
    Rails.logger.info "MaintenanceReport: #{findings.size} checks, #{problems.size} problem(s)"
  end
end
