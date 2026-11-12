# frozen_string_literal: true

require "test_helper"

# The one email about entries left on a retired VAT code row.
class TaxCodeRetirementNotificationJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    ActionMailer::Base.deliveries.clear
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @code = TaxCode.find_by!(scheme: "gb_vat", key: "sale_standard")
    # income_sales is 410001: entity 10.
    @posting = postings(:deposit_income)
    @posting.update_column(:tax_code_id, @code.id)
    @posting.journal_entry.update_column(:journal_reference, "INV-77")
    @entity = Entity.find_by!(code: "10")
  end

  def full_access_admins = AdminEntity.with_full_access.where(entity: @entity).map(&:admin)

  test "emails each full-access bookkeeper of the business, listing the entry" do
    admins = full_access_admins
    assert admins.any?, "fixture: entity 10 needs a full-access admin"

    assert_emails admins.count { |a| a.email_address.present? } do
      TaxCodeRetirementNotificationJob.perform_now(tax_code_ids: [ @code.id ])
    end
    body = ActionMailer::Base.deliveries.last.text_part.body.to_s
    assert_match "INV-77", body
    assert_match @code.label, body
  end

  test "co-admins who cannot change entries are not told" do
    readers = AdminEntity.where(entity: @entity).where.not(access_level: :full_access).map(&:admin)
    TaxCodeRetirementNotificationJob.perform_now(tax_code_ids: [ @code.id ])
    recipients = ActionMailer::Base.deliveries.flat_map(&:to)
    readers.each { |r| assert_not_includes recipients, r.email_address }
  end

  test "nothing to say about a row no entry uses" do
    @posting.update_column(:tax_code_id, nil)
    assert_no_emails { TaxCodeRetirementNotificationJob.perform_now(tax_code_ids: [ @code.id ]) }
  end
end
