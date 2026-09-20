# frozen_string_literal: true

# EntityGroupMembership stops being "rows only while in a family" and becomes a
# COMPLETE, gap-free scope timeline for every entity, from its creation date
# onward. A solo stretch is a real row with entity_group_id NULL; there is
# always exactly one open row per entity. Archive generation reads this to know
# which scope (own code, or g<id>) an entity's postings belong to on any date.
#
# Boundary convention: a stint is [starts_on .. ends_on] inclusive, the next
# begins ends_on + 1. A membership change dated D closes the old stint at D-1
# and opens the new at D — so "who was here on D" has exactly one answer.
class BackfillMembershipTimeline < ActiveRecord::Migration[8.1]
  def up
    add_index :entity_group_memberships, [ :entity_group_id, :starts_on ],
              name: "index_egm_on_group_and_start", if_not_exists: true
    add_index :entity_group_memberships, [ :entity_id, :starts_on ],
              name: "index_egm_on_entity_and_start", if_not_exists: true

    # The timeline is an append-only historical record: a stint keeps its
    # entity_group_id (which scope its archives live under) even after that
    # EntityGroup is destroyed. So no FK — a dangling id there is meaningful,
    # not a violation.
    if foreign_key_exists?(:entity_group_memberships, :entity_groups)
      remove_foreign_key :entity_group_memberships, :entity_groups
    end

    say_with_time "rebuilding membership timelines" do
      rebuilt = 0
      Entity.reset_column_information
      Entity.find_each do |entity|
        rebuild_timeline(entity)
        rebuilt += 1
      end
      rebuilt
    end
  end

  def down
    remove_index :entity_group_memberships, name: "index_egm_on_group_and_start", if_exists: true
    remove_index :entity_group_memberships, name: "index_egm_on_entity_and_start", if_exists: true
    add_foreign_key :entity_group_memberships, :entity_groups unless foreign_key_exists?(:entity_group_memberships, :entity_groups)
    # The timeline rows themselves are left in place — harmless, and there is no
    # faithful inverse of "make the history complete".
  end

  private

  def rebuild_timeline(entity)
    created = entity.created_at.to_date
    existing = entity.entity_group_memberships
                     .where.not(entity_group_id: nil)
                     .order(:starts_on, :id)
                     .to_a

    # (starts_on, entity_group_id-or-nil) segment starts, in order.
    segments = []
    cursor   = created

    existing.each do |row|
      break if cursor.nil?
      join_on = [ row.starts_on, created ].max
      segments << [ cursor, nil ] if join_on > cursor          # solo gap before the join
      segments << [ join_on, row.entity_group_id ]
      cursor = row.ends_on ? row.ends_on + 1 : nil             # nil = this stint is still open
    end

    segments << [ cursor, entity.entity_group_id ] if cursor   # trailing stint matches "now"

    # Collapse any accidental consecutive same-scope segments.
    segments = segments.each_with_object([]) do |(start_on, gid), acc|
      acc << [ start_on, gid ] unless acc.last && acc.last[1] == gid
    end

    entity.entity_group_memberships.delete_all
    segments.each_with_index do |(start_on, gid), i|
      ends_on = segments[i + 1] ? segments[i + 1][0] - 1 : nil
      EntityGroupMembership.create!(
        entity_id: entity.id, entity_group_id: gid,
        starts_on: start_on, ends_on: ends_on
      )
    end
  end
end
