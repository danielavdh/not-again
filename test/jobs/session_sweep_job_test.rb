require "test_helper"

# Sessions do not expire on their own, and two kinds of account are exempt from
# the second factor that would otherwise end them — the demo, and the helper who
# only photographs receipts. This job is the only thing that ever removes those.
#
# The ages are policy, so what is asserted here is the shape: quiet accounts of
# the exempt kinds go, busy ones stay, and ordinary admins are never touched.
class SessionSweepJobTest < ActiveJob::TestCase
  setup do
    # As in production: the demo has an entity to itself. AdminEntity refuses to
    # let a public passwordless account share one with a real admin.
    entity = entities(:family_biz)
    entity.admin_entities.joins(:admin).where(admins: { demo: false }).destroy_all

    @demo = Admin.create!(username: "demo-sweep", demo: true, password: SecureRandom.hex(16))
    AdminEntity.create!(admin: @demo, entity: entity, access_level: :read_only)

    @helper = admins(:upload_only)
    @normal = admins(:one)
  end

  # Both columns: the demo rule reads updated_at (touched as they browse) and
  # the helper rule reads created_at (how long the session has been alive).
  def session_for(admin, quiet_for:)
    admin.sessions.create!(user_agent: "test", ip_address: "127.0.0.1").tap do |s|
      s.update_columns(created_at: quiet_for.ago, updated_at: quiet_for.ago)
    end
  end

  test "a demo session that has gone quiet is removed" do
    s = session_for(@demo, quiet_for: 2.hours)
    SessionSweepJob.perform_now
    assert_not Session.exists?(s.id)
  end

  test "a demo session still in use is left alone" do
    s = session_for(@demo, quiet_for: 5.minutes)
    SessionSweepJob.perform_now
    assert Session.exists?(s.id), "someone still reading was thrown out"
  end

  # The whole point of the upload_receipts role is not being asked to log in
  # again, so an hour of quiet must not touch them. Only a year does.
  test "an hour of quiet does not evict a receipt helper" do
    s = session_for(@helper, quiet_for: 2.hours)
    SessionSweepJob.perform_now
    assert Session.exists?(s.id), "a helper was logged out on the demo's schedule"
  end

  test "a receipt helper silent for over a year is removed" do
    # The fixtures already give this helper a receipt dated today, which is the
    # correct answer to "still using it" — age it, or there is no silence.
    Receipt.where(uploaded_by: @helper).update_all(created_at: 2.years.ago)

    s = session_for(@helper, quiet_for: 13.months)
    SessionSweepJob.perform_now
    assert_not Session.exists?(s.id)
  end

  # A helper is judged on receipts, not on browsing: uploading IS the only
  # reason they open the app.
  test "a helper who uploaded recently keeps an old session" do
    s = session_for(@helper, quiet_for: 13.months)
    receipts(:linked_receipt).update_columns(uploaded_by_id: @helper.id,
                                             created_at: 1.week.ago)
    SessionSweepJob.perform_now
    assert Session.exists?(s.id), "someone still uploading was logged out"
  end

  # And the reverse, which is why the session age is checked as well: someone
  # coming back after a long silence logs in BECAUSE they have a receipt to
  # upload. Evicting them between signing in and photographing it would make the
  # account impossible to use.
  test "a helper who has just signed in is not evicted for an old silence" do
    s = session_for(@helper, quiet_for: 1.minute)
    SessionSweepJob.perform_now
    assert Session.exists?(s.id), "evicted in the moment between logging in and uploading"
  end

  # An ordinary admin's session is ended by the OTP gate, not by this job —
  # sweeping them here would log people out on a rule nobody chose.
  test "an ordinary admin is never swept, however long they have been quiet" do
    s = session_for(@normal, quiet_for: 5.years)
    SessionSweepJob.perform_now
    assert Session.exists?(s.id)
  end

  test "the demo's age does not leak onto other exempt accounts" do
    demo_row   = session_for(@demo,   quiet_for: 2.hours)
    helper_row = session_for(@helper, quiet_for: 2.hours)
    SessionSweepJob.perform_now
    assert_not Session.exists?(demo_row.id)
    assert Session.exists?(helper_row.id)
  end
end
