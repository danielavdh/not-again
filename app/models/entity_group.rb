# frozen_string_literal: true

# A consolidation group: two or more entities that are aspects of one business.
# Cross-entity journal entries are allowed within the group, and the group's
# balance sheet and trial balance consolidate over all members. An entity with
# no group is its own group.
class EntityGroup < ApplicationRecord

  has_many :entities,
           class_name: 'Entity',
           foreign_key: :entity_group_id,
           dependent: :nullify
  # The membership timeline is append-only history: a destroyed group's stints
  # keep their entity_group_id, the scope their archives live under. No FK, so
  # nothing to nullify and nothing to block the destroy.
  has_many :entity_group_memberships

  validates :name, presence: true, uniqueness: { case_sensitive: false }

  # Ungroup each member the ordinary way BEFORE dependent: :nullify's callback-
  # free update_all — prepend, or it runs after and finds no members. That way
  # every member's timeline gets its group stint closed and a solo stint opened,
  # and the group's archives are flushed.
  before_destroy :ungroup_members, prepend: true

  def codes
    entities.pluck(:code)
  end

  # Resolves a form value to a family: an existing numeric id → that family;
  # blank → nil (ungroup); anything else → a family with that name, created if
  # new.
  def self.resolve(value)
    value = value.to_s.strip
    return nil if value.blank?

    if value.match?(/\A\d+\z/) && (existing = find_by(id: value))
      existing
    else
      find_or_create_by(name: value)
    end
  end

  private

  def ungroup_members
    entities.reload.each { |e| e.update!(entity_group: nil) }
  end
end
