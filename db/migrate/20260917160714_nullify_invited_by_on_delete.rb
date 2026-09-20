# frozen_string_literal: true

# invited_by is history now, not a permission relationship (Admin#can_manage?
# reads AdminEntity links instead — see the session this shipped in). The FK
# had no on_delete behaviour, so deleting an inviter was blocked outright by
# Postgres the moment anyone still had invited_by_id pointing at them — this
# is what a plain admin.destroy actually hit once dependent: :destroy came
# off the has_many. Nullifying instead of restricting matches what the
# column now means: a fact that stops being true once its subject is gone,
# same shape as Account's parent_id (dependent: :nullify on the children).
class NullifyInvitedByOnDelete < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :admins, column: :invited_by_id
    add_foreign_key :admins, :admins, column: :invited_by_id, on_delete: :nullify
  end
end
