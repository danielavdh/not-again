# frozen_string_literal: true

# How many decimal places a currency actually has, from ISO 4217.
#
# The app divides and formats by 100 everywhere, which is right for about 155
# of the world's ~180 currencies and wrong for the rest: a yen has no subunit
# at all, a Kuwaiti dinar has a thousand fils. Adding JPY today would make
# every yen figure a hundred times too small, silently, on screen and in every
# export.
#
# Nothing READS this column yet — see docs/gitignored/after-deploy-todo.md for
# the work that will. Recording the fact first means a currency added before
# then is already carrying the right answer, rather than needing to be found
# and corrected afterwards.
class AddMinorUnitToCurrencies < ActiveRecord::Migration[8.1]
  def change
    add_column :currencies, :minor_unit, :integer, null: false, default: 2

    reversible do |dir|
      dir.up do
        Currency::MINOR_UNITS.each do |code, places|
          execute ActiveRecord::Base.sanitize_sql_array(
            [ "UPDATE currencies SET minor_unit = ? WHERE code = ?", places, code ]
          )
        end
      end
    end
  end
end
