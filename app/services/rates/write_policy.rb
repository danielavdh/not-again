# frozen_string_literal: true

module Rates
  # Who may write an exchange rate.
  #
  # fetched  =>  the shared series every entity reads  =>  sudo
  # typed    =>  one business's own rate               =>  write access to that
  # entity
  #
  # There is no third category: a typed rate is never global, which makes the
  # whole thing two rules.
  #
  # A transcribed publisher's figure — a 2018 HMRC rate, say — is still typed,
  # not fetched. Where it came from goes in the evidence note, which is what the
  # note is for: nobody fetched it, a person typed it.
  class WritePolicy
    def self.writable?(rate, admin)
      return false unless admin
      return true if admin.sudo?

      # A global row can only have been fetched, and the shared series is not
      # an ordinary admin's to change.
      return false if rate.entity_id.blank?

      entity_writable?(rate, admin)
    end

    # An entity's own rate — a group rate, a chosen bank, a documented
    # Tageskurs. Theirs to set, and used for their figures alone.
    def self.entity_writable?(rate, admin)
      entity = Entity.find_by(id: rate.entity_id)
      return false unless entity

      admin.writable_entity_codes.include?(entity.code)
    end

    # { rate_id => true/false } for a LIST, without asking per row. Kept even
    # though the rule is cheap, because the index renders 25 rows and
    # entity_writable? would otherwise look up an entity for each.
    def self.writable_map(rates, admin)
      rates = Array(rates)
      return {} if rates.empty?
      return rates.index_by(&:id).transform_values { true }  if admin&.sudo?
      return rates.index_by(&:id).transform_values { false } unless admin

      writable_codes = admin.writable_entity_codes
      entity_codes = Entity.where(id: rates.filter_map(&:entity_id))
                                .pluck(:id, :code).to_h

      rates.index_by(&:id).transform_values do |rate|
        rate.entity_id.present? &&
          writable_codes.include?(entity_codes[rate.entity_id])
      end
    end

    # READ access — the shared series is everyone's, but an entity's own rate,
    # and its evidence note, is only for an admin linked to that entity at any
    # level. Looser than writable?, which needs write access; stricter than "any
    # admin". Guards show/edit and scopes the index.
    def self.visible?(rate, admin)
      return false unless admin
      return true if admin.sudo?
      return true if rate.entity_id.blank?

      admin.accessible_entity_ids.include?(rate.entity_id)
    end

    # Why an admin may not write this, in words a person can act on. nil when
    # they may.
    def self.refusal_reason(rate, admin)
      return nil if writable?(rate, admin)
      return :no_entity_access if rate.entity_id.present?

      :shared_series
    end
  end
end
