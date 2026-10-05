# frozen_string_literal: true

module CrossEntity
  # The receiving business deleted its half of a cross-entity gift, which severs
  # the link and leaves the donor's own entry standing but matching nothing.
  #
  # Worth an email because the donor paid for something they could not deduct
  # themselves, on the understanding that the other business would use it — and
  # nothing else would ever tell them it had been handed back.
  #
  # Addressed to the admins who run the donor's books (full access on that
  # entity). Silent when there are none: an orphaned entity has nobody to tell.
  class GiftReturnedNotificationJob < ApplicationJob
    queue_as :default

    # `locale` is explicit rather than inherited: a job has no request to take
    # one from, and a silent fall-through to the default is the A9 defect.
    def perform(gift_posting_id:, amount:, currency:, locale: I18n.default_locale.to_s)
      gift = Posting.find_by(id: gift_posting_id)
      # Gone with its own entry, or the link was restored before this ran.
      return if gift.nil? || gift.cross_entity_link_id.present?

      entity = Entity.find_by(code: gift.account&.entity_code)
      return if entity.nil?

      recipients(entity).each do |admin|
        AdminMailer.with(admin: admin, entity: entity, gift: gift,
                         amount: amount, currency: currency, locale: locale)
                   .cross_entity_gift_returned.deliver_now
      end
    end

    private

    def recipients(entity)
      Admin.joins(:admin_entities)
           .where(admin_entities: { entity_id: entity.id, access_level: :full_access })
           .where.not(email_address: [ nil, "" ])
           .distinct
    end
  end
end
