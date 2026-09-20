class AddClaimedAtToAdmins < ActiveRecord::Migration[8.1]
  # nil means "still a draft" — set only by Admin#claim! (the forced
  # confirm-email-then-set-a-password flow at a new coadmin's first login)
  # or explicitly at creation for a path that was never a draft in the
  # first place (create_as_sudo). Existing admins predate the whole
  # concept and have all, definitionally, already been using the app —
  # backfilled claimed at their own created_at, not left nil (which would
  # make every real admin in the database vanish from managed_admins'
  # count-as-a-claimed-coadmin logic and, worse, become deletable by
  # whoever granted them access originally).
  def up
    add_column :admins, :claimed_at, :datetime
    execute "UPDATE admins SET claimed_at = created_at"
  end

  def down
    remove_column :admins, :claimed_at
  end
end
