class AddVerifiedAtToAdmins < ActiveRecord::Migration[8.1]
  def change
    add_column :admins, :verified_at, :datetime
  end
end
