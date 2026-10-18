# frozen_string_literal: true

# A reverse charge no longer posts its two cancelling legs: the return works the
# figure out from the net at report time, translated at the authority's rate,
# like every other figure in a tax report. The legs already in the books net to
# zero in every control account, so removing them changes no balance.
class RemoveReverseChargeLegs < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DELETE FROM postings
      WHERE tax_for_posting_id IN (
        SELECT net.id
        FROM postings net
        JOIN tax_codes codes ON codes.id = net.tax_code_id
        WHERE codes.reverse_charge
      )
    SQL
  end

  # Derived rows: nothing to restore by hand.
  def down; end
end
