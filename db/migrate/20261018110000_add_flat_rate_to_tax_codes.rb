# frozen_string_literal: true

# One boolean could not say what the flat rate does with a code. Notice 733
# and 700/12 have three answers for a supply outside the scheme: accounted
# box-for-box as under normal rules (a reverse charge on services), declared
# but not reclaimed (postponed import VAT, a Northern Ireland acquisition), or
# nothing at all (import VAT paid at the border). Nil is inside the scheme.
class AddFlatRateToTaxCodes < ActiveRecord::Migration[8.1]
  def change
    add_column    :tax_codes, :flat_rate, :string
    remove_column :tax_codes, :outside_flat_rate, :boolean, default: false, null: false
  end
end
