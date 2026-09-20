# Per-admin choice of how grouped money is written (thousands / decimal
# separator + symbol side). Nil = follow the UI language. Values are the slugs
# in NumberFormat::FORMATS.
class AddPreferredNumberFormatToAdmins < ActiveRecord::Migration[8.1]
  def change
    add_column :admins, :preferred_number_format, :string
  end
end
