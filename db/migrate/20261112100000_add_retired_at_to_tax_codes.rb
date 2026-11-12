# frozen_string_literal: true

# A code row the catalogue no longer declares, kept because entries still use
# it and no current row books them the same way. Set when the loader first
# keeps it, which is also when the bookkeepers are told; cleared if the row
# comes back into the catalogue.
class AddRetiredAtToTaxCodes < ActiveRecord::Migration[8.1]
  def change
    add_column :tax_codes, :retired_at, :datetime
  end
end
