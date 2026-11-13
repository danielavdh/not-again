# frozen_string_literal: true

# Appended to a save notice when the save had to create a VAT control account:
# an account appearing unannounced is worse than one the user made, and they
# may want to rename it. The model that created them keeps the list
# (JournalEntry#created_vat_accounts, Entity#created_vat_accounts).
module VatAccountsNotice
  extend ActiveSupport::Concern

  def vat_accounts_notice(created)
    return nil if created.blank?

    t("accounts.vat_account_created",
      count: created.size,
      accounts: created.map { |a| "#{a.code} #{a.name}" }.to_sentence)
  end
end
