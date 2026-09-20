# frozen_string_literal: true

require "test_helper"

class SignInEventTest < ActiveSupport::TestCase
  def request_double(ip: "203.0.113.9", agent: "Mozilla/5.0")
    Struct.new(:remote_ip, :user_agent).new(ip, agent)
  end

  # ⚠️ THE LOAD-BEARING ONE. A logging table that can refuse a legitimate login
  # has done more damage than no logging ever would.
  test "a failure to record does not raise into the sign-in" do
    SignInEvent.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, "disk full" }) do
      assert_nothing_raised do
        assert_nil SignInEvent.record(outcome: :failed, username: "x", request: request_double)
      end
    end
  end

  # The whole reason this is a table and not a column on admins.
  test "an attempt on a username that matches nobody is still recorded" do
    assert_difference("SignInEvent.count", 1) do
      SignInEvent.record(outcome: :failed, username: "no-such-person", request: request_double)
    end
    assert_nil SignInEvent.last.admin_id
    assert_equal "no-such-person", SignInEvent.last.username_attempted
  end

  # A user agent is whatever the client claims it is.
  test "an absurd user agent cannot bloat the row" do
    SignInEvent.record(outcome: :failed, username: "x", request: request_double(agent: "A" * 90_000))

    assert_equal SignInEvent::MAX_AGENT, SignInEvent.last.user_agent.length
  end

  test "a missing user agent is not an error" do
    assert_difference("SignInEvent.count", 1) do
      SignInEvent.record(outcome: :failed, username: "x", request: request_double(agent: nil))
    end
    assert_nil SignInEvent.last.user_agent
  end

  # Retention is a promise about personal data, so it is asserted about the
  # world — a row older than the window is gone — not about the scope's SQL.
  test "the sweep drops what is past retention and keeps what is not" do
    old    = SignInEvent.create!(outcome: :failed, username_attempted: "old", created_at: (SignInEvent::RETENTION + 1.day).ago)
    recent = SignInEvent.create!(outcome: :failed, username_attempted: "recent", created_at: 1.day.ago)
    edge   = SignInEvent.create!(outcome: :failed, username_attempted: "edge", created_at: (SignInEvent::RETENTION - 1.hour).ago)

    SignInEvent.expired.delete_all

    assert_not SignInEvent.exists?(old.id), "a record past retention survived the sweep"
    assert SignInEvent.exists?(recent.id)
    assert SignInEvent.exists?(edge.id), "a record inside the window was swept"
  end

  # The schedule in config/recurring.yml calls this by name as a string. A
  # rename that misses the YAML leaves the sweep silently never running, and the
  # data then lives forever.
  test "the scheduled sweep command actually works" do
    command = YAML.safe_load_file(Rails.root.join("config/recurring.yml"))
                  .dig("production", "sign_in_event_sweep", "command")

    assert_equal "SignInEvent.expired.delete_all", command
    SignInEvent.create!(outcome: :failed, username_attempted: "old", created_at: 1.year.ago)
    assert_nothing_raised { eval(command) }
    assert_equal 0, SignInEvent.where(username_attempted: "old").count
  end

  test "summary_since counts by outcome and ignores what is outside the window" do
    SignInEvent.create!(outcome: :signed_in, username_attempted: "a", created_at: 1.hour.ago)
    SignInEvent.create!(outcome: :failed, username_attempted: "b", created_at: 1.hour.ago)
    SignInEvent.create!(outcome: :failed, username_attempted: "c", created_at: 1.hour.ago)
    SignInEvent.create!(outcome: :otp_failed, username_attempted: "d", created_at: 1.hour.ago)
    SignInEvent.create!(outcome: :failed, username_attempted: "e", created_at: 30.days.ago)

    counts = SignInEvent.summary_since(7.days.ago)

    assert_equal 1, counts["signed_in"]
    assert_equal 2, counts["failed"], "an event outside the window was counted"
    assert_equal 1, counts["otp_failed"]
  end
  # THE REGRESSION. The foreign key defaulted to RESTRICT, which made any admin
  # who had ever signed in undeletable — AdminsController#destroy and the whole
  # offboarding path died on a PG::ForeignKeyViolation.
  test "an admin who has signed in can still be deleted" do
    admin = Admin.create!(username: "leaver", password: "password123", email_address: "leaver@example.org")
    SignInEvent.create!(outcome: :signed_in, username_attempted: "leaver", admin: admin)

    assert_nothing_raised { admin.destroy! }
  end

  # And the record must not go with them: "that account was deleted" is not a
  # reason to lose the evidence that somebody signed in as it.
  test "deleting an admin keeps the attempt and the name it was made with" do
    admin = Admin.create!(username: "leaver", password: "password123", email_address: "leaver@example.org")
    SignInEvent.create!(outcome: :otp_failed, username_attempted: "leaver", admin: admin)

    admin.destroy!
    event = SignInEvent.find_by(username_attempted: "leaver")

    assert_not_nil event, "the record of the attempt was destroyed with the account"
    assert_nil event.admin_id
    assert event.otp_failed?
  end
end
