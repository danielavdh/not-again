# frozen_string_literal: true

module Archives
  # A family dropped below two members, by a departure or the group being
  # destroyed. No sibling close will ever trigger its archives again, and
  # Archives::SweepJob iterates entities, so it never revisits a group with no
  # current members. Flush every outstanding calendar year for that scope now.
  class FlushJob < ApplicationJob
    queue_as :default

    def perform(scope_key)
      Archives::Lock.with(scope_key) { Archives::YearEnd.flush(scope_key) }
    end
  end
end
