# frozen_string_literal: true

# Tells the bookkeepers whose entries still use a VAT code row the catalogue no
# longer declares, and that no current row books the same way (another rate, or
# no row for that date). The loader keeps such a row instead of deleting it;
# this is the one time anyone is told. The Monday maintenance report repeats it
# until the row is gone.
class TaxCodeRetirementNotificationJob < ApplicationJob
  queue_as :default

  def perform(tax_code_ids:)
    codes = TaxCode.where(id: tax_code_ids).index_by(&:id)
    return if codes.empty?

    # Plucked, not loaded: date, reference and memo are all the mail shows.
    rows = Posting.where(tax_code_id: codes.keys)
                  .joins(:account, :journal_entry)
                  .distinct
                  .pluck("accounts.code", "postings.tax_code_id", "journal_entries.entry_date",
                         "journal_entries.journal_reference", "journal_entries.memo")
    by_entity_code = rows.group_by { |(account_code, *)| account_code.to_s[1, 2] }

    by_admin = Hash.new { |h, k| h[k] = [] }
    AdminEntity.full_access_admins_by_entity_code(by_entity_code.keys).each do |entity_code, admins|
      admins.each { |admin| by_admin[admin].concat(by_entity_code[entity_code]) }
    end

    by_admin.each do |admin, admin_rows|
      next if admin.email_address.blank?

      entries = admin_rows.map { |(_, code_id, date, reference, memo)|
        [ codes[code_id], date, reference, memo ]
      }.uniq.sort_by { |(code, date)| [ code.key, date ] }
      AdminMailer.with(admin: admin, entries: entries).tax_codes_retired.deliver_now
    end
  end
end
