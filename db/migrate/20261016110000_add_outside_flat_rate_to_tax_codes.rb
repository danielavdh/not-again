class AddOutsideFlatRateToTaxCodes < ActiveRecord::Migration[8.1]
  def change
    # Excluded from flat-rate turnover (Notice 733): reverse-charge supplies are
    # "dealt with outside of the Flat Rate Scheme ... but recorded in boxes 1 and
    # 4 as you would under normal accounting".
    #
    # A separate flag from `reverse_charge`, which does NOT mean what its name
    # suggests: it means "derives two cancelling legs". The supplier side of a
    # domestic reverse charge derives nothing (it is rated 0) and so carries
    # reverse_charge: false while being, in law, exactly a reverse-charge supply.
    add_column :tax_codes, :outside_flat_rate, :boolean, null: false, default: false
  end
end
