class AddFlatRateToReports < ActiveRecord::Migration[8.1]
  def change
    # Basis points, as tax_codes.rate_bps already is: 14.5% is 1450. NULL means
    # a full return, which is almost every report.
    #
    # On the REPORT rather than the report group: the report IS the period, so a
    # rate change, or joining or leaving the scheme mid-year, dates correctly by
    # construction and cannot rewrite a quarter already filed.
    add_column :reports, :flat_rate_bps, :integer, null: true
  end
end
