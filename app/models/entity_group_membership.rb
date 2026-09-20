# frozen_string_literal: true

# One row per stretch an entity spent in one scope — a family (entity_group_id
# set) or on its own (NULL). Together, an entity's rows form a COMPLETE, gap-
# free timeline from its creation date to now, with exactly one open row
# (ends_on NULL).
#
# Written entirely by Entity (open_initial_membership_stint on create,
# track_group_membership_change on an entity_group_id change); no controller or
# view of its own. This is what archive generation reads to answer "which scope
# did this entity's postings on this date belong to" — entity_group_id on Entity
# only ever answers "right now".
#
# Boundary: [starts_on .. ends_on] inclusive; the next stint starts ends_on + 1.
class EntityGroupMembership < ApplicationRecord
  belongs_to :entity
  belongs_to :entity_group, optional: true

  validates :starts_on, presence: true
  validate :ends_on_not_before_starts_on

  scope :open, -> { where(ends_on: nil) }
  scope :covering, ->(date) { where("starts_on <= ? AND (ends_on IS NULL OR ends_on >= ?)", date, date) }
  # Stints that touch [from, to] at all (either bound may equal).
  scope :overlapping, ->(from, to) {
    where("starts_on <= ? AND (ends_on IS NULL OR ends_on >= ?)", to, from)
  }

  # The scope key this stint represents: "g<id>" for a family, the entity's
  # own two-digit code for a solo stretch.
  def scope_key
    entity_group_id ? "g#{entity_group_id}" : entity.code
  end

  private

  def ends_on_not_before_starts_on
    return if ends_on.nil? || starts_on.nil?
    errors.add(:ends_on, "can't be before starts_on") if ends_on < starts_on
  end
end
