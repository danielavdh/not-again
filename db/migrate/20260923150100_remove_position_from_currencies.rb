class RemovePositionFromCurrencies < ActiveRecord::Migration[8.1]
  def change
    remove_column :currencies, :position, :integer
  end
end
