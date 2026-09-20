class CreateEntityGroupMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :entity_group_memberships do |t|
      t.references :entity, null: false, foreign_key: true
      # Nullable, mirroring Entity's own entity_group_id: EntityGroup already
      # nullifies (never cascades) when a group is destroyed — memberships
      # follow the same rule, so a destroyed group's history survives as an
      # orphaned record rather than vanishing or blocking the destroy.
      t.references :entity_group, null: true, foreign_key: true
      t.date :starts_on, null: false
      t.date :ends_on

      t.timestamps
    end

    # An entity can only be an open (current) member of one family at a time —
    # ends_on IS NULL is "still in it". Partial index, not a validation-only
    # guard: this is what archive generation trusts when it asks "who was
    # here on this date", so the database enforces it can never go stale.
    add_index :entity_group_memberships, :entity_id,
              unique: true,
              where: "ends_on IS NULL",
              name: "index_one_open_membership_per_entity"
  end
end
