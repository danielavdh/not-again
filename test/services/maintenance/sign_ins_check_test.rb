# frozen_string_literal: true

require "test_helper"

class SignInsCheckTest < ActiveSupport::TestCase
  def check = Maintenance::WeeklyCheck.new(s3: Object.new, backup_bucket: nil).send(:sign_ins)

  def event(outcome, at: 1.hour.ago)
    SignInEvent.create!(outcome: outcome, username_attempted: "x", created_at: at)
  end

  test "a quiet week is not a problem" do
    3.times { event(:signed_in) }
    2.times { event(:failed) }

    assert check.ok, "ordinary mistyping was reported as a problem"
    assert_includes check.detail, "2 failed"
  end

  # ⚠️ ANY otp_failed is an alarm, however few. It means the password was right.
  test "one failed second factor is enough to raise the alarm" do
    event(:otp_failed)

    assert_not check.ok
    assert_includes check.detail, "CORRECT password"
  end

  test "failures beyond what typing explains raise the alarm on their own" do
    Maintenance::WeeklyCheck::FAILED_SIGN_IN_ALARM.times { event(:failed) }

    assert_not check.ok
    assert_includes check.detail, "more failures than typing explains"
  end

  # The window is what makes the weekly figure mean anything.
  test "an attack that ended long ago does not keep raising the alarm" do
    event(:otp_failed, at: 30.days.ago)

    assert check.ok, "an event outside the 7-day window was still counted"
  end

  # A week with nothing at all still reports, because the mail always goes.
  test "a week with no attempts at all still produces a finding" do
    assert check.ok
    assert_includes check.detail, "0 signed in"
  end
end
