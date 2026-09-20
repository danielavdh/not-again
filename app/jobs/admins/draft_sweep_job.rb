# A draft coadmin (Admin#draft?) is a live secret in two hands — the granting
# full-access admin chose its username and password, and the intended person may
# never have used them. Left unclaimed indefinitely it is a permanent access
# ambiguity: an account with a real password nobody has taken ownership of.
#
# Admin::UNCLAIMED_LIFETIME, measured from creation, not from the last email
# sent — a forgotten invite is still a forgotten invite after three resends. The
# granting admin can already delete a draft outright at any time; this is the
# backstop for the one nobody got around to.
module Admins
  class DraftSweepJob < ApplicationJob
    queue_as :default

    def perform
      count = Admin.where(claimed_at: nil)
                   .where(created_at: ...Admin::UNCLAIMED_LIFETIME.ago).destroy_all.size
      return if count.zero?

      Rails.logger.info("Admins::DraftSweepJob: removed #{count} unclaimed draft admin(s)")
    end
  end
end
