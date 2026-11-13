# frozen_string_literal: true

# A VAT return marked final locks the entries of its period. The clean-up entry
# booked at that moment points back at its report, so reopening can find it and
# no user can edit it.
class AddVatFinalToReports < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :finalized_at, :datetime
    add_reference :journal_entries, :vat_report, foreign_key: { to_table: :reports }, index: true
  end
end
