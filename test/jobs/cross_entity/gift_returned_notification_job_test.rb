# frozen_string_literal: true

require "test_helper"

# The receiver giving a gift back leaves the donor holding a cost they could not
# deduct themselves, now matching nothing. Nothing else would tell them.
class CrossEntity::GiftReturnedNotificationJobTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @link = SecureRandom.uuid
    @je1  = JournalEntry.create!(entry_date: Date.current, postings_attributes: [
      { account_id: accounts(:personal_drawings).id, amount: 10_000,
        entry_type: :debit, cross_entity_link_id: @link },
      { account_id: accounts(:bank_gbp).id, amount: 10_000, entry_type: :credit }
    ])
    @je2 = JournalEntry.create!(entry_date: Date.current, postings_attributes: [
      { account_id: accounts(:daughter_capital).id, amount: 10_000,
        entry_type: :credit, cross_entity_link_id: @link },
      { account_id: accounts(:daughter_expenses).id, amount: 10_000, entry_type: :debit }
    ])
    @gift = @je1.postings.detect { |p| p.account.personal? }
    ActionMailer::Base.deliveries.clear
  end

  # The drawings account is 610001, so the donor is entity 10 (family_biz).
  def donor_admins
    Admin.joins(:admin_entities)
         .where(admin_entities: { entity_id: entities(:family_biz).id, access_level: :full_access })
         .distinct
  end

  test "severing the gift tells the admins who run the donor's books" do
    assert_operator donor_admins.count, :>, 0, "no donor-side admins in the fixtures"

    perform_enqueued_jobs do
      @je2.destroy!
    end

    recipients = ActionMailer::Base.deliveries.flat_map(&:to)
    assert_equal donor_admins.map(&:email_address).sort, recipients.sort
  end

  test "the donor deleting their own entry tells nobody — they know" do
    perform_enqueued_jobs do
      @je1.destroy!
    end

    assert_empty ActionMailer::Base.deliveries
  end

  # Purging a business severs every gift it ever received, and means the
  # business is gone rather than anybody returning anything. EntityPurgeService
  # uses delete_all, so no callback of this kind runs at all — asserted here so
  # a switch to destroy_all could not start sending them unnoticed.
  test "purging the receiving business sends nothing" do
    entities(:daughter).admin_entities.destroy_all
    entities(:daughter).refresh_orphan_state!

    perform_enqueued_jobs do
      EntityPurgeService.call(entities(:daughter).reload)
    end

    assert_empty ActionMailer::Base.deliveries
  end

  test "nothing is sent when the link was put back before the job ran" do
    gift_id = @gift.id
    @je2.destroy!
    Posting.where(id: gift_id).update_all(cross_entity_link_id: SecureRandom.uuid)

    assert_no_emails do
      CrossEntity::GiftReturnedNotificationJob.perform_now(
        gift_posting_id: gift_id, amount: 10_000, currency: "GBP", locale: "en"
      )
    end
  end
end
