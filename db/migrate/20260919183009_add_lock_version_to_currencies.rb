# frozen_string_literal: true

# Rails optimistic locking: a stale edit raises ActiveRecord::StaleObjectError
# instead of silently overwriting a rename that already cascaded elsewhere.
class AddLockVersionToCurrencies < ActiveRecord::Migration[8.1]
  def change
    add_column :currencies, :lock_version, :integer, null: false, default: 0
  end
end
