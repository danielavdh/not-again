# frozen_string_literal: true

# Who tried to get in, and whether they got there.
#
# SCOPED TO AUTHENTICATION ON PURPOSE. This is not a record of what anyone did
# with the books and must not become one: a journal entry is already its own
# record, and copying every write would build a second, worse set of books.
#
# The entry that earns the table is otp_failed — a correct password stopped only
# by the second factor. That is someone who HAS a password, which is a different
# kind of news from someone guessing at one.
class SignInEvent < ApplicationRecord
  belongs_to :admin, optional: true

  # `failed` covers both a wrong password and an unknown username, and is
  # deliberately not split: telling them apart would reintroduce the user
  # enumeration Admin.authenticate_by goes out of its way to prevent.
  enum :outcome, { signed_in: 0, failed: 1, otp_failed: 2 }

  # Personal data — an IP address identifies a person — kept only as long as it
  # serves the purpose. Attacks are noticed in days; a log from last spring
  # informs no decision anyone would still take.
  RETENTION = 90.days

  # A user agent is whatever the client says it is, and can be megabytes of it.
  MAX_AGENT = 255

  scope :since, ->(time) { where(created_at: time..) }
  scope :problems, -> { where(outcome: [ outcomes[:failed], outcomes[:otp_failed] ]) }
  # Swept nightly from config/recurring.yml. A scope rather than logic in the
  # schedule file, so the retention rule is somewhere a test can reach it.
  scope :expired, -> { where(created_at: ...RETENTION.ago) }

  # NEVER let this break a sign-in. A logging table that can refuse a legitimate
  # login — a full disk, a lock, a half-applied migration — has done more damage
  # than the absence of logging ever would. It fails silently into the Rails log
  # and the request carries on.
  def self.record(outcome:, username:, request:, admin: nil)
    create!(
      outcome:            outcome,
      username_attempted: username.to_s.first(255),
      admin:              admin,
      ip_address:         request.remote_ip,
      user_agent:         request.user_agent&.first(MAX_AGENT)
    )
  rescue StandardError => e
    Rails.logger.error("SignInEvent.record failed: #{e.class}: #{e.message}")
    nil
  end

  # Counted in SQL, never loaded: this runs against a table that a sustained
  # attack can push into the hundreds of thousands of rows.
  def self.summary_since(time)
    since(time).group(:outcome).count
  end
end
