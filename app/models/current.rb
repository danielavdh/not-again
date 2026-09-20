class Current < ActiveSupport::CurrentAttributes
  attribute :session
  # The admin's `preferred_number_format` slug (or nil for the language
  # default), so CurrencyConfig can honour it without every call site passing
  # it. Set per request in ApplicationController; a background job that formats
  # money for a specific admin (TaxExportJob) sets it for its own run.
  attribute :number_format
  # HMRC fraud prevention headers for the current request, built from the
  # request + admin + browser-collected data. Only Hmrc::Client reads them.
  attribute :fraud_prevention_headers
  # Set while a cross-entity pair (JE₁ + its JE₂) is saved together, so the
  # per-posting mirror guard (Posting#cross_entity_link_consistent) doesn't fire
  # on
  # the transient state where one side is updated before the other. The concern
  # re-verifies the mirror once BOTH are written. See CrossEntityJournalEntries.
  attribute :skip_cross_entity_consistency
  # Set while the app itself rewrites the closing entries it generated — the
  # in-period recalculation, and reopening a year. Those entries are read-only
  # to
  # users (JournalEntry#app_owned_close?), so every legitimate rewrite must
  # announce itself here.
  attribute :app_closing_entry_write
  delegate :admin, to: :session, allow_nil: true
end
