class CreateTermsAgreements < ActiveRecord::Migration[8.1]
  def change
    # Who agreed to what, and when. §13 of known-limitations.md: an admin is
    # shown the terms and has to agree before doing anything else, and this
    # applies to every admin who has not yet agreed to the CURRENT version —
    # a brand new admin and one who has been in the database for years are the
    # same case here. There is deliberately no backfill: an existing admin with
    # no row simply hits the gate on their next request.
    create_table :terms_agreements do |t|
      # ⚠️ Same lesson as sign_in_events: on_delete: :nullify, not the default
      # RESTRICT — an admin who has agreed must still be deletable. Losing the
      # admin_id link is fine; losing the proof that someone agreed is not, so
      # admin_username is a snapshot, taken at the moment of agreement, that
      # survives the admin being deleted.
      t.references :admin, foreign_key: { on_delete: :nullify }, null: true
      t.string :admin_username, null: false
      t.string :version, null: false
      t.datetime :created_at, null: false
      # No updated_at: an agreement is a thing that happened, never revised.
    end

    # Stops a double-submitted form from writing two rows for the same
    # agreement. Silent once admin_id is nullified — Postgres does not treat
    # NULL = NULL, so historical rows never collide with each other.
    add_index :terms_agreements, [ :admin_id, :version ], unique: true
  end
end
