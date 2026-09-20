# frozen_string_literal: true

require "test_helper"

module Reports
  class TaxCsvTest < ActiveSupport::TestCase
    setup do
      @entity   = entities(:family_biz)
      @accounts = [accounts(:income_sales), accounts(:expenses_general)]
      @start_date = Date.current.beginning_of_year
      @end_date   = Date.current
      @admin      = admins(:two)
    end

    # ==================== Explicit params (job path) ====================

    test "generates CSV with correct headers using explicit params" do
      csv = TaxCsv.new(
        accounts: @accounts,
        entity: @entity,
        scheme: "gb_self_employment",
        start_date: @start_date,
        end_date: @end_date,
        display_currency: "GBP",
        admin: @admin
      ).generate

      rows = CSV.parse(csv)
      assert_equal [I18n.t("reports.csv.section"), I18n.t("reports.csv.category_key"), I18n.t("reports.csv.label"), I18n.t("reports.csv.reference"), I18n.t("reports.csv.amount", currency: "GBP")], rows.first
    end

    test "includes NET row using explicit params" do
      csv = TaxCsv.new(
        accounts: @accounts,
        entity: @entity,
        scheme: "gb_self_employment",
        start_date: @start_date,
        end_date: @end_date,
        display_currency: "GBP",
        admin: @admin
      ).generate

      rows = CSV.parse(csv)
      assert rows.any? { |r| r.first == I18n.t("reports.csv.net") }
    end

    test "does not raise when entity has no tax schemes" do
      assert_nothing_raised do
        TaxCsv.new(
          accounts: @accounts,
          entity: @entity,
          scheme: "gb_self_employment",
          start_date: @start_date,
          end_date: @end_date,
          display_currency: "EUR",
          admin: @admin
        ).generate
      end
    end

    # ==================== breakdown_data ====================

    # breakdown_data feeds the submission archive — the record of what was
    # filed. Two buckets, putting anything that was not income into expenses,
    # made tax deducted at source an expense on that record. A figure that is
    # neither now says so, and stays out of both totals.
    test "a figure that is neither income nor expense gets its own bucket" do
      TaxCategory.find_or_create_by!(country_code: "gb", scheme: "gb_self_employment",
                                          tax_year: 2026, key: "tax_taken_off") do |c|
        c.section  = "other"
        c.position = 210
      end

      code    = @entity.code
      withheld = Account.create!(code: "5#{code}910", name: "Tax deducted at source",
                                      account_type: :expense, active: true,
                                      tax_scheme: "gb_self_employment",
                                      tax_category_key: "tax_taken_off")
      bank     = Account.create!(code: "1#{code}910", name: "Bank acct", account_type: :asset,
                                      currency: "GBP")

      je = JournalEntry.new(entry_date: @start_date + 1.day, posted: true, memo: "CIS")
      je.postings.build(account: withheld, entry_type: :debit,  amount: 25_000)
      je.postings.build(account: bank,     entry_type: :credit, amount: 25_000, currency: "GBP")
      je.save!

      result = TaxCsv.new(
        accounts:         [ withheld ],
        entity:           @entity,
        scheme:           "gb_self_employment",
        start_date:       @start_date,
        end_date:         @end_date,
        display_currency: "GBP",
        admin:            @admin
      ).breakdown_data

      assert_equal %w[tax_taken_off], result[:other].map { |i| i[:key] },
                   "it belongs in the other bucket"
      assert_empty result[:expenses], "and must not be counted as an expense"
      assert_equal 0, result[:total_expenses]
      assert_equal 0, result[:net], "neither total moves because of it"
    end

    test "breakdown_data returns hash with expected keys" do
      result = TaxCsv.new(
        accounts:         @accounts,
        entity:           @entity,
        scheme:           "gb_self_employment",
        start_date:       @start_date,
        end_date:         @end_date,
        display_currency: "GBP",
        admin:            @admin
      ).breakdown_data

      assert_respond_to result, :[]
      assert result.key?(:income)
      assert result.key?(:expenses)
      assert result.key?(:total_income)
      assert result.key?(:total_expenses)
      assert result.key?(:net)
    end

    test "breakdown_data income and expenses are arrays" do
      result = TaxCsv.new(
        accounts:         @accounts,
        entity:           @entity,
        scheme:           "gb_self_employment",
        start_date:       @start_date,
        end_date:         @end_date,
        display_currency: "GBP",
        admin:            @admin
      ).breakdown_data

      assert_kind_of Array, result[:income]
      assert_kind_of Array, result[:expenses]
    end

    test "breakdown_data net equals total_income minus total_expenses" do
      result = TaxCsv.new(
        accounts:         @accounts,
        entity:           @entity,
        scheme:           "gb_self_employment",
        start_date:       @start_date,
        end_date:         @end_date,
        display_currency: "GBP",
        admin:            @admin
      ).breakdown_data

      assert_equal result[:total_income] - result[:total_expenses], result[:net]
    end

    test "breakdown_data items have label amount and key fields when present" do
      result = TaxCsv.new(
        accounts:         @accounts,
        entity:           @entity,
        scheme:           "gb_self_employment",
        start_date:       @start_date,
        end_date:         @end_date,
        display_currency: "GBP",
        admin:            @admin
      ).breakdown_data

      all_items = result[:income] + result[:expenses]
      # Verify structure: if items exist they have the right keys; empty is also
      # valid
      all_items.each do |item|
        assert item.key?(:label),  "item missing :label"
        assert item.key?(:amount), "item missing :amount"
        assert item.key?(:key),    "item missing :key"
      end
      assert_kind_of Array, all_items
    end

    test "breakdown_data does not raise when no postings exist" do
      assert_nothing_raised do
        TaxCsv.new(
          accounts:         @accounts,
          entity:           @entity,
          scheme:           "gb_self_employment",
          start_date:       Date.new(1900, 1, 1),
          end_date:         Date.new(1900, 12, 31),
          display_currency: "GBP",
          admin:            @admin
        ).breakdown_data
      end
    end
  end
end
