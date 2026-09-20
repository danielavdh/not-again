class ReplaceTermsAgreementsWithAdminColumns < ActiveRecord::Migration[8.1]
  def change
    # A separate table was the wrong shape for this. It borrowed the
    # sign_in_events pattern (own table, FK on_delete: :nullify, a username
    # snapshot) to survive a HOSTILE deletion — someone covering their tracks.
    # Terms agreement has no such adversary: nobody is trying to hide that they
    # were informed, so there is nothing to protect by outliving the admin row.
    # It belongs directly on Admin.
    drop_table :terms_agreements

    # version: WHAT they agreed to. Comparing this against Admin::TERMS_VERSION
    # is what re-gates everyone automatically the day that constant changes —
    # no data migration needed to force a re-agreement.
    add_column :admins, :terms_agreed_version, :string
    # at: WHEN. Its own column, not admins.updated_at — that column moves on
    # every unrelated edit (an admin's own "save preferences" flow included),
    # so it cannot be trusted to mean "this is when they agreed".
    add_column :admins, :terms_agreed_at, :datetime
  end
end
