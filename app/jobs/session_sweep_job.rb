# Sessions do not expire: the cookie is permanent and logging out is the only
# thing that removes a row, so anything never logged out of stays valid. For
# most admins a lapsed second factor ends the session; this job covers the two
# kinds exempt from OTP, which are never re-challenged.
#
# The two are measured differently, because they leave different traces.
#
# DEMO   — a stranger reading made-up books, who creates nothing. There is no
# record of them anywhere except the session row, so the row is touched as they
# browse and quiet is read from it. An hour, because nobody reads a demo for an
# hour.
# HELPER — someone whose whole role is photographing receipts. "Still using it"
# and "has uploaded something" are the same sentence, and the receipts already
# record it, so nothing needs touching. A year, because being asked to log in
# again is the friction the role exists to avoid.
#
# NOT admins.last_seen for either: it is written once at login, so for someone
# who never logs out it stays fixed at the day they first signed in.
class SessionSweepJob < ApplicationJob
  queue_as :default

  DEMO_QUIET   = 1.hour
  HELPER_QUIET = 1.year

  def perform
    demo   = sweep_demo
    helper = sweep_helpers

    return if (demo + helper).zero?

    Rails.logger.info("SessionSweepJob: removed #{demo} demo and #{helper} upload-only sessions")
  end

  private

  def sweep_demo
    Session.where(admin_id: Admin.where(demo: true).select(:id))
           .where(updated_at: ...DEMO_QUIET.ago)
           .delete_all
  end

  # Both conditions, and the second is not optional: a helper coming back after
  # a long gap logs in precisely BECAUSE they have a receipt to upload. Judging
  # on the old upload alone would evict them in the moment between signing in
  # and photographing anything.
  def sweep_helpers
    cutoff = HELPER_QUIET.ago

    # where.not(uploaded_by_id: nil) is load-bearing, not tidiness. A receipt
    # attached by an ordinary admin carries no uploader, and SQL's NOT IN
    # matches NOTHING when the subquery contains a NULL — one such row and the
    # sweep silently stops finding anybody, with no error to say so.
    uploaded_since = Receipt.where(created_at: cutoff..)
                            .where.not(uploaded_by_id: nil)
                            .select(:uploaded_by_id)
    silent_admins  = Admin.upload_receipts_only.where(demo: false).where.not(id: uploaded_since)

    Session.where(admin_id: silent_admins.select(:id))
           .where(created_at: ...cutoff)
           .delete_all
  end
end
