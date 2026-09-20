# frozen_string_literal: true

# invited_by was history only by the time this runs — nothing in the app
# reads it for a permission decision any more (see the migration that
# nullified its FK, same session). Daniela's call: a column nobody can act
# on and nobody will remember the meaning of in a year is baggage, not
# information — remove it rather than let it sit there unused.
class RemoveInvitedByFromAdmins < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :admins, column: :invited_by_id
    remove_index :admins, :invited_by_id
    remove_column :admins, :invited_by_id
  end

  def down
    add_column :admins, :invited_by_id, :bigint
    add_index :admins, :invited_by_id
    add_foreign_key :admins, :admins, column: :invited_by_id, on_delete: :nullify
  end
end
