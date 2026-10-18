class AddSubtractsToTaxCategories < ActiveRecord::Migration[8.1]
  def change
    # The mirror of `includes`. Box 5 of a UK VAT return is "the difference
    # between boxes 3 and 4" and roll_up could only add, so nothing ever fed it
    # and it printed 0.00 on a form meant to be copied. The Dutch return needs
    # the same thing for 5c (5a minus 5b).
    add_column :tax_categories, :subtracts, :string, array: true, default: [], null: false
  end
end
