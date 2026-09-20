class AddSignInEventsAndUniqueUsername < ActiveRecord::Migration[8.1]
  def change
    # Logging in is `Admin.authenticate_by(username:)`, which is `find_by` — it
    # takes the FIRST match. The uniqueness validation alone cannot stop two
    # concurrent creates from producing a pair, and the loser of that race could
    # then never sign in at all. email_address has had this index all along;
    # username, the column actually used to authenticate, did not.
    change_column_null :admins, :username, false
    add_index :admins, :username, unique: true

    # Who tried to get in. Deliberately scoped to authentication: it is not a
    # record of what anyone did with the books, and must not grow into one.
    create_table :sign_in_events do |t|
      # As typed, and the reason this is a table rather than a column on admins:
      # a failed attempt usually matches no admin at all, and "someone tried
      # `admin` four hundred times" is the entry worth having.
      t.string  :username_attempted, null: false
      # Null whenever the username matched nothing.
      # ⚠️ on_delete: :nullify, NOT the default. The default is RESTRICT, which
      # makes an admin who has ever signed in undeletable — it breaks
      # AdminsController#destroy and offboarding with a foreign key violation.
      # The event must outlive the account anyway: username_attempted still says
      # who it was, and "this account was later deleted" is not a reason to lose
      # the record that somebody tried to get in with it.
      t.references :admin, foreign_key: { on_delete: :nullify }, null: true
      # ⚠️ `failed` is deliberately NOT split into wrong-password and
      # no-such-username. Admin.authenticate_by returns nil for both, and Rails
      # spends the same bcrypt time on a missing user as on a real one precisely
      # so the two cannot be told apart from outside. Recording the difference
      # would mean an extra existence query and would hand back the user
      # enumeration that costs buys. Nothing is lost: username_attempted is
      # stored, so joining against admins when the table is READ answers it.
      t.integer :outcome, null: false
      t.string  :ip_address
      t.string  :user_agent

      # No updated_at: a row is a thing that happened and is never revised.
      t.datetime :created_at, null: false
    end

    # created_at for the 90-day sweep, and for "since last Monday" in the weekly
    # report. The pair for reading the failures back out.
    add_index :sign_in_events, :created_at
    add_index :sign_in_events, [ :outcome, :created_at ]
  end
end
