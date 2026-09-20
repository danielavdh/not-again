# frozen_string_literal: true
require "test_helper"

class Hmrc::PayloadBuilderTest < ActiveSupport::TestCase
  setup do
    @entity = entities(:personal)
  end

  # A period with no mapped accounts/activity must still be a valid nil return,
  # not an empty body (HMRC rejects that with RULE_INCORRECT_OR_EMPTY_BODY_SUBMITTED).
  test "gb_self_employment nil period sends explicit zero turnover" do
    payload = Hmrc::PayloadBuilder.new(
      entity:     @entity,
      accounts:   [],
      start_date: Date.new(2026, 4, 6),
      end_date:   Date.new(2026, 7, 5),
      scheme:     :gb_self_employment
    ).build

    assert_equal({ periodStartDate: "2026-04-06", periodEndDate: "2026-07-05" }, payload[:periodDates])
    assert_equal({ turnover: 0.0 }, payload[:periodIncome])
    refute payload.key?(:periodExpenses)
  end

  # The scheme here is OUR slug, "gb_property" — the value stored on accounts
  # and catalogue rows — not HMRC's endpoint naming ("property"), which is what
  # the client uses. Passing the latter matches no accounts, silently.

  def property_builder(start_date:, end_date:, accounts: [])
    Hmrc::PayloadBuilder.new(
      entity:     @entity,
      accounts:   accounts,
      start_date: start_date,
      end_date:   end_date,
      scheme:     :gb_property
    )
  end

  test "property cumulative (2025-26+) nil period uses ukProperty with zero periodAmount" do
    payload = property_builder(start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5)).build

    assert_equal "2026-04-06", payload[:fromDate]
    assert_equal "2026-07-05", payload[:toDate]
    assert_equal({ income: { periodAmount: 0.0 } }, payload[:ukProperty])
    refute payload.key?(:ukNonFhlProperty)
  end

  test "property legacy (<=2024-25) nil period uses ukNonFhlProperty wrapper" do
    payload = property_builder(start_date: Date.new(2024, 4, 6), end_date: Date.new(2024, 7, 5)).build

    assert_equal({ income: { periodAmount: 0.0 } }, payload[:ukNonFhlProperty])
    refute payload.key?(:ukProperty)
  end

  # Tax deducted at source is reported inside HMRC's INCOME object while not
  # being income. Routing the payload on `section` would file it as an expense;
  # totalling the report on `api_section` would inflate turnover. Hence two
  # columns.
  test "a figure filed under income but not counted as income lands in the income object" do
    builder = property_builder(start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5))
    builder.define_singleton_method(:category_totals) do
      {
        "rent_income"    => { amount: 120_000, payload_section: "income", api_field: "periodAmount" },
        "tax_taken_off"  => { amount:  10_000, payload_section: "income", api_field: "taxDeducted" }
      }
    end

    assert_equal({ "periodAmount" => 1200.0, "taxDeducted" => 100.0 },
                 builder.build[:ukProperty][:income])
    assert_nil builder.build[:ukProperty][:expenses]
  end

  # The catalogue must actually carry that, not just be capable of it.
  test "both GB schemes declare where tax taken off is filed" do
    Dir[Rails.root.join("db/tax_categories/gb_*.yml")].each { |f| TaxCategoryLoader.call(f) }

    {
      "gb_self_employment" => "taxTakenOffTradingIncome",
      "gb_property"     => "taxDeducted"
    }.each do |scheme, field|
      cat = TaxCategory.find_by!(scheme: scheme, key: "tax_taken_off")
      assert_equal field,    cat.api_field,       "#{scheme} api_field"
      assert_equal "income", cat.payload_section, "#{scheme} goes in the income object"
      assert_equal "other",  cat.section,         "#{scheme} is not counted as income"
    end
  end

  test "property maps categories to flat api fields under the era wrapper" do
    builder = property_builder(start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5))
    # amounts are in cents; bypass the DB aggregation to test the JSON shape.
    # api_field now travels with the category rather than coming from a second file.
    builder.define_singleton_method(:category_totals) do
      {
        "rent_income"        => { amount: 120_000, payload_section: "income",   api_field: "periodAmount" },
        "rent_rates_repairs" => { amount:  50_000, payload_section: "expenses", api_field: "premisesRunningCosts" }
      }
    end
    payload = builder.build

    assert_equal(
      { income: { "periodAmount" => 1200.0 }, expenses: { "premisesRunningCosts" => 500.0 } },
      payload[:ukProperty]
    )
  end

  # Drives category_totals for real rather than stubbing it: with the wrong
  # scheme name it selects no accounts, returns {}, and the submission goes out
  # EMPTY without complaint.
  test "property builds real figures from tagged accounts, not an empty nil return" do
    TaxCategory.find_or_create_by!(country_code: "gb", scheme: "gb_property",
                                        tax_year: 2026, key: "rent_income") do |c|
      c.section = "income"
      c.api_field = "periodAmount"
      c.position = 10
    end
    TaxCategory.where(scheme: "gb_property", key: "rent_income")
                    .update_all(api_field: "periodAmount", section: "income")

    code   = @entity.code
    income = Account.create!(code: "4#{code}901", name: "Rent received",
                                  account_type: :income,
                                  tax_scheme: "gb_property", tax_category_key: "rent_income")
    bank   = Account.create!(code: "1#{code}901", name: "Bank", account_type: :asset, currency: "GBP")

    je = JournalEntry.new(entry_date: Date.new(2026, 5, 1), posted: true, memo: "rent")
    je.postings.build(account: income, entry_type: :credit, amount: 90_000)
    je.postings.build(account: bank,   entry_type: :debit,  amount: 90_000, currency: "GBP")
    je.save!

    payload = property_builder(start_date: Date.new(2026, 4, 6),
                               end_date:   Date.new(2026, 7, 5),
                               accounts:   [ income ]).build

    assert_equal({ "periodAmount" => 900.0 }, payload[:ukProperty][:income],
                 "the submission must carry the real figure, not a zero nil return")

    # audit M9: the archived CSV breakdown and the filed payload must agree —
    # they now read the SAME Reports::TaxCategoryTotals.
    csv = Reports::TaxCsv.new(accounts: [ income ], entity: @entity, scheme: :gb_property,
      start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5),
      display_currency: "GBP", admin: admins(:sudo)).breakdown_data
    assert_equal 90_000, csv[:total_income]
    assert_equal(90_000, Reports::TaxCategoryTotals.new(
      accounts: [ income ], scheme: :gb_property, from: Date.new(2026, 4, 6),
      to: Date.new(2026, 7, 5), display_currency: "GBP", entity: @entity
    ).totals["rent_income"][:amount])
  end

  # The other tests stub category_totals or pass accounts: []. This one drives
  # the whole path — a real posting in a foreign currency, a real published
  # rate — and asserts HMRC receives the ledger figure converted at that rate.
  test "a EUR-currency posting reaches the payload converted at the published rate" do
    TaxCategory.find_or_create_by!(country_code: "gb", scheme: "gb_property", tax_year: 2026, key: "rent_income") do |c|
      c.section = "income"; c.api_field = "periodAmount"; c.position = 10
    end
    TaxCategory.where(scheme: "gb_property", key: "rent_income").update_all(api_field: "periodAmount", section: "income")
    ExchangeRate.where(from_currency: %w[EUR GBP], to_currency: %w[EUR GBP]).delete_all
    on = Date.new(2026, 5, 1)
    # HMRC publishes GBP-based; the translator inverts. GBP->EUR 1.25 ⇒ EUR->GBP 0.80.
    ExchangeRate.create!(from_currency: "GBP", to_currency: "EUR", source: "hmrc", rate: 1.25,
                         effective_date: on, valid_from: on.beginning_of_month, valid_to: on.end_of_month)

    code   = @entity.code
    rent   = Account.create!(code: "4#{code}902", name: "EUR rent", account_type: :income,
                                  tax_scheme: "gb_property", tax_category_key: "rent_income")
    eur_bank = Account.create!(code: "1#{code}902", name: "EUR bank", account_type: :asset, currency: "EUR")
    je = JournalEntry.new(entry_date: Date.new(2026, 5, 10), posted: true, memo: "eur rent")
    je.postings.build(account: eur_bank, entry_type: :debit,  amount: 100_000, currency: "EUR")
    je.postings.build(account: rent,     entry_type: :credit, amount: 100_000)
    je.save!

    payload = property_builder(start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5),
                               accounts: [ rent ]).build

    # €1,000.00 × 0.80 = £800.00
    assert_equal({ "periodAmount" => 800.0 }, payload[:ukProperty][:income])
  end
end
