# frozen_string_literal: true

# A figure on the return that is not a transaction: a prepayment the authority
# fixed in advance and the return deducts — Germany's Sondervorauszahlung for a
# Dauerfristverlängerung, Kz 39, entered in the last Voranmeldung of the year.
# Minor units. Only a scheme whose catalogue names a prepayment_category shows
# the field.
class AddPrepaymentToReports < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :prepayment, :integer
  end
end
