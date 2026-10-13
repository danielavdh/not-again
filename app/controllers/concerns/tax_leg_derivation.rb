# frozen_string_literal: true

# Where the controllers ask for VAT legs, and learn that a control account had
# to be created. Always called BEFORE the bank leg is worked out — that leg is
# the sum of the others, so it only comes to the gross once the legs are in.
module TaxLegDerivation
  extend ActiveSupport::Concern

  def derive_tax_legs_for(journal_entry)
    return unless journal_entry.tax_coded?

    created = journal_entry.derive_tax_legs
    @vat_accounts_created = created if created.any?
  end

  # Appended to the save notice: an account appearing unannounced is worse than
  # one the user made, and they may want to rename it.
  def vat_accounts_notice
    return nil if @vat_accounts_created.blank?

    t("accounts.vat_account_created",
      count: @vat_accounts_created.size,
      accounts: @vat_accounts_created.map { |a| "#{a.code} #{a.name}" }.to_sentence)
  end
end
