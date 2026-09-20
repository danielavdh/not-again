# frozen_string_literal: true

module Archives
  # The safety net under closing: a scope (an entity or a family) that never
  # closes a year still ends up with one permanent, undeletable archive for it.
  #
  # Runs 1 Jan and forces the year TWO back from today — a full year's grace,
  # since nobody has last year done on New Year's Day. One archive per scope,
  # not per member: family members dedupe on their shared scope key.
  class SweepJob < ApplicationJob
    queue_as :default

    def perform
      year = Date.current.year - 2

      seen = {}
      Entity.find_each do |entity|
        scope_key = Archives::Storage.scope_key_for(entity)
        next if seen[scope_key]
        seen[scope_key] = true

        Archives::Lock.with(scope_key) do
          Archives::YearEnd.force(scope_key, year)
        end
      end
    end
  end
end
