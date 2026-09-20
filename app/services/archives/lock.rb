# frozen_string_literal: true

module Archives
  # Serialises everything that reads-then-writes a scope's closing entries and
  # archives: year-end close, reopen, correction rebuild, sweep, dissolved-
  # family flush. Keyed on the SCOPE — a family key or an entity code — so two
  # siblings closing at once queue instead of racing, which is what doubled
  # retained earnings.
  #
  # A Postgres transaction-level advisory lock: the second caller blocks until
  # the first transaction commits, then proceeds and re-reads. Released
  # automatically on commit or rollback, so nothing leaks on an exception.
  class Lock
    def self.with(scope_key)
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute(
          "SELECT pg_advisory_xact_lock(hashtext(#{ApplicationRecord.connection.quote("archive:#{scope_key}")}))"
        )
        yield
      end
    end

    # The scope key for an entity's CURRENT scope — what a close or correction
    # on that entity must lock.
    def self.key_for(entity)
      Storage.scope_key_for(entity)
    end
  end
end
