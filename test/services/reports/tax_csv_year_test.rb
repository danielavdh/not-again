# frozen_string_literal: true

require "test_helper"

module Reports
  # The export must be built from the catalogue AS IT STOOD for the period it
  # covers. Asking for categories without mentioning the year meant that the
  # moment a second year existed it took whichever row the database returned
  # last, per key, with no guaranteed order.
  #
  # The model test proves the lookup; this proves the export actually uses it.
  class TaxCsvYearTest < ActiveSupport::TestCase
    setup do
      @entity   = entities(:family_biz)
      @account  = accounts(:expenses_general)
      @admin    = admins(:two)

      # Tag the account with a key we control, and give that key a DIFFERENT
      # reference in two British tax years.
      @account.update!(tax_scheme: "gb_self_employment", tax_category_key: "office_costs")

      TaxCategory.where(scheme: "gb_self_employment", key: "office_costs").delete_all
      make_category(2028, "OLD-24")
      make_category(2029, "NEW-27")
    end

    def make_category(year, export_column)
      TaxCategory.create!(
        country_code: "gb", scheme: "gb_self_employment", tax_year: year,
        key: "office_costs", label: "Office costs", export_column: export_column,
        section: "expenses", position: 1
      )
    end

    # A figure inside the period, or the account contributes no row at all and
    # every assertion below passes vacuously on nil.
    def post_expense(date)
      je = JournalEntry.new(entry_date: date, posted: true, memo: "office")
      je.postings.build(account: @account, entry_type: :debit,  amount: 10_000, currency: "GBP")
      je.postings.build(account: accounts(:bank_gbp), entry_type: :credit, amount: 10_000, currency: "GBP")
      je.save!
    end

    def reference_column_for(end_date)
      post_expense(end_date - 1.day)

      csv = TaxCsv.new(
        accounts: [@account], entity: @entity, scheme: "gb_self_employment",
        start_date: end_date - 2.months, end_date: end_date,
        display_currency: "GBP", admin: @admin
      ).generate

      row = CSV.parse(csv).find { |r| r[1] == "office_costs" }
      row && row[3] # the Reference column
    end

    # The state that made the old lookup lossy: two rows, same key, different
    # years — index_by keeps whichever the database returned last. Asserted here
    # so the tests below are visibly about a real ambiguity rather than a
    # hypothetical one.
    #
    # A "fails before the fix" demonstration is not available: the old behaviour
    # was undefined, not wrong-in-a-fixed-way.
    test "there really are two candidate rows for this key" do
      assert_equal 2, TaxCategory.where(scheme: "gb_self_employment", key: "office_costs").count
    end

    # A British tax year is numbered by the year it ENDS in: 2028/29 runs
    # 6 Apr 2028 to 5 Apr 2029 and is tax_year 2029.
    test "a period inside 2027/28 uses the 2028 catalogue" do
      assert_equal "OLD-24", reference_column_for(Date.new(2028, 3, 31))
    end

    test "a period inside 2028/29 uses the 2029 catalogue" do
      assert_equal "NEW-27", reference_column_for(Date.new(2028, 7, 5))
    end

    # The boundary itself: 5 April is the last day of the old year, 6 April the
    # first of the new one.
    test "5 April is still the old year, 6 April is the new one" do
      assert_equal "OLD-24", reference_column_for(Date.new(2028, 4, 5))
      assert_equal "NEW-27", reference_column_for(Date.new(2028, 4, 6))
    end

    # Contributors skip years in which nothing changed, so a period after the
    # last file still resolves — to the newest one that is not in the future.
    test "a later period with no catalogue of its own falls back" do
      assert_equal "NEW-27", reference_column_for(Date.new(2031, 6, 30))
    end
  end
end
