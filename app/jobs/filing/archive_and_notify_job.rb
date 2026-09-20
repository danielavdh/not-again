# frozen_string_literal: true

module Filing
  # Runs after a successful (synchronous) submission to the tax authority:
  # archives the rendered HTML to storage, then — only once that succeeds —
  # sends the confirmation email. Sequential on purpose so the emailed
  # view link always resolves to an already-stored document.
  class ArchiveAndNotifyJob < ApplicationJob
    queue_as :default

    # This runs AFTER the authority has accepted the submission — the filing is
    # done, only the record-keeping is left. A transient storage or mail failure
    # must not lose the archived document or the confirmation, so retry hard;
    # only a genuine bug survives five polynomially-spaced attempts and lands in
    # solid_queue_failed_executions for a human. Re-upload is idempotent (the
    # filename is deterministic); a retry after a successful send is a duplicate
    # confirmation, which beats none (audit C2).
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(entity_id:, admin_id:, scheme:, start_date:, end_date:,
                view_url:, filename:, html:, locale: I18n.default_locale.to_s)
      entity = Entity.find(entity_id)
      admin  = Admin.find(admin_id)

      Filing::Storage.upload(filename, html)

      AdminMailer.with(
        admin:    admin,
        entity:   entity,
        scheme:   scheme,
        start_d:  start_date.to_date,
        end_d:    end_date.to_date,
        view_url: view_url,
        locale:   locale
      ).filing_submitted.deliver_now
    end
  end
end
