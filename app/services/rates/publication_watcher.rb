# frozen_string_literal: true

module Rates
  # Notices when a publisher starts carrying a currency it did not carry before,
  # and tells the businesses that have been entering that rate by hand.
  #
  # WITHOUT THIS THE CHANGE IS INVISIBLE, and invisibly wrong. An entity-owned
  # rate outranks the published series wherever it covers the date —
  # deliberately, because it is the business's declared choice — so the day the
  # ECB adds hryvnia, the fetcher stores it and every report goes on using the
  # typed figure, for ever, with nothing saying the published one now exists.
  #
  # Whether to switch is the business's call and usually not mid-year: most
  # authorities require the choice to be applied consistently across a tax
  # period. The app's job is to say it, not to decide it.
  module PublicationWatcher
    # Wraps a fetch: compares the currencies this source published before and
    # after, and notifies on anything new.
    #
    # A before/after comparison rather than a stored "notified" flag — it needs
    # no column, cannot go stale, and re-running a fetch notifies nobody twice
    # because the second run adds nothing.
    def self.around(source)
      before = published_currencies(source)
      result = yield
      (published_currencies(source) - before).each { |code| notify(code, source) }
      result
    end

    def self.published_currencies(source)
      ExchangeRate.where(source: source, entity_id: nil)
                       .distinct
                       .pluck(:from_currency, :to_currency)
                       .flatten
                       .uniq
    end

    # Everyone with write access to an entity that holds its own rate in this
    # currency. Nobody else needs to know: an entity on the published series
    # already had it, and this changes nothing for them.
    def self.notify(code, source)
      entity_ids = ExchangeRate.where.not(entity_id: nil)
                                    .where(from_currency: code)
                                    .or(ExchangeRate.where.not(entity_id: nil)
                                                         .where(to_currency: code))
                                    .distinct.pluck(:entity_id)
      return if entity_ids.empty?

      entities = Entity.where(id: entity_ids).pluck(:code, :name).to_h
      return if entities.empty?

      Admin.joins(admin_entities: :entity)
           .where(entities: { code: entities.keys })
           .distinct
           .find_each do |admin|
        mine = entities.values_at(*(admin.writable_entity_codes & entities.keys)).compact
        next if mine.empty?

        AdminMailer.with(admin: admin, code: code, source: source,
                         entities: mine, locale: I18n.default_locale.to_s)
                   .published_rate_now_available.deliver_later
      end
    end
  end
end
