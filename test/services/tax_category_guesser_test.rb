# frozen_string_literal: true
require "test_helper"

# Suggesting a category from the account's NAME. Reading digit 4 of the account
# code could only be right if the account had been numbered to a convention
# nothing enforces, and was silently wrong when it had not.
class TaxCategoryGuesserTest < ActiveSupport::TestCase
  setup do
    # The real catalogues, not fixtures: the keywords that ship are the thing
    # under test, and a keyword that suggests the wrong box is the failure that
    # matters.
    Dir[Rails.root.join("db/tax_categories/*.yml")].sort.each do |path|
      TaxCategoryLoader.call(path)
    end
  end

  def guess(scheme, name)
    TaxCategoryGuesser.for_scheme(scheme).guess(name)
  end

  # ── the names a bookkeeper actually writes ────────────────────────────────

  test "UK self-employment accounts find their box" do
    {
      "Sales"                => "sales_income",
      "Turnover"             => "sales_income",
      "Wages and salaries"   => "staff_costs",
      "Motor expenses"       => "travel_costs",
      "Rent and rates"       => "premises_running_costs",
      "Stationery"           => "admin_costs",
      "Bank charges"         => "financial_charges",
      "Accountancy fees"     => "professional_fees",
      "Entertaining clients" => "business_entertainment",
      "Depreciation"         => "depreciation",
      "Subcontractors"       => "payments_to_subcontractors"
    }.each { |name, key| assert_equal key, guess("gb_self_employment", name), name }
  end

  test "UK property accounts find theirs, which are different boxes entirely" do
    {
      "Rental income"      => "rent_income",
      "Ground rent"        => "rent_rates_insurance",
      "Insurance"          => "rent_rates_insurance",
      "Property repairs"   => "repairs_maintenance",
      "Mortgage interest"  => "residential_finance_costs",
      "Letting agent fees" => "legal_professional_fees",
      "Gardening"          => "cost_of_services"
    }.each { |name, key| assert_equal key, guess("gb_property", name), name }
  end

  # The reason substring matching exists: German builds compounds, and the
  # head is at the END. A prefix match would find none of these.
  test "German compounds match on the word inside them" do
    assert_equal "miete_geschaeftsraeume", guess("de_euer", "Büromiete")
    assert_equal "waren_rohstoffe",        guess("de_euer", "Wareneingang")
    assert_equal "schuldzinsen",           guess("de_vermietung", "Darlehenszinsen")
    assert_equal "erhaltungsaufwand",      guess("de_vermietung", "Renovierung")
    assert_equal "finanzaufwand",          guess("ch_selbst", "Bankspesen")
  end

  test "hyphens and case are no obstacle on either side" do
    assert_equal "kfz_steuern_versicherungen", guess("de_euer", "Kfz-Steuer")
    assert_equal "kfz_steuern_versicherungen", guess("de_euer", "KFZ VERSICHERUNG")
    assert_equal "telekommunikation",          guess("de_euer", "telefon")
  end

  # ── what it refuses to answer ─────────────────────────────────────────────

  test "an account that means nothing to this form gets no suggestion" do
    assert_nil guess("gb_self_employment", "Bank account")
    assert_nil guess("de_euer", "Girokonto")
    assert_nil guess("gb_property", "")
  end

  # The specific box wins over the general one, or "Kfz-Versicherung" would tie
  # with plain insurance and be answered with silence.
  test "the more specific phrase beats the more general word" do
    assert_equal "kfz_steuern_versicherungen", guess("de_euer", "Kfz-Versicherung")
    assert_equal "beitraege_versicherungen",   guess("de_euer", "Betriebsversicherung")
    assert_equal "kfz_leasing",                guess("de_euer", "Kfz-Leasing")
    assert_equal "miete_leasing_bewegliche",   guess("de_euer", "Leasing")
  end

  test "an even tie is answered with nothing rather than a coin toss" do
    scheme = "tie_test"
    TaxCategory.create!(country_code: "gb", scheme: scheme, tax_year: 2026,
                        key: "left",  label: "Left",  keywords: [ "shared" ])
    TaxCategory.create!(country_code: "gb", scheme: scheme, tax_year: 2026,
                        key: "right", label: "Right", keywords: [ "shared" ])

    assert_nil guess(scheme, "Shared thing")
  end

  # ── scoping ───────────────────────────────────────────────────────────────

  test "a suggestion never comes from another scheme's catalogue" do
    # "Büromiete" is an EÜR box; the UK property catalogue has no such thing.
    assert_nil guess("gb_property", "Büromiete")
    # …and travel exists in both UK schemes, each with its own key.
    assert_equal "travel_costs", guess("gb_property", "Travel")
    assert_equal "travel_costs", guess("gb_self_employment", "Car and van")
  end

  test "a scheme with no catalogue at all suggests nothing" do
    assert_nil guess("no_such_scheme", "Anything")
  end

  # Same resolution the reports use, so a suggestion can never come from an
  # edition a submission would not.
  test "the year asked for decides which edition answers" do
    TaxCategory.create!(country_code: "gb", scheme: "year_test", tax_year: 2026,
                        key: "old", label: "Old", keywords: [ "widgets" ])
    TaxCategory.create!(country_code: "gb", scheme: "year_test", tax_year: 2030,
                        key: "new", label: "New", keywords: [ "widgets" ])

    assert_equal "old", TaxCategoryGuesser.for_scheme("year_test", year: 2027).guess("Widgets")
    assert_equal "new", TaxCategoryGuesser.for_scheme("year_test", year: 2031).guess("Widgets")
    assert_equal "new", TaxCategoryGuesser.for_scheme("year_test").guess("Widgets")
  end

  # ── in bulk ───────────────────────────────────────────────────────────────

  test "guess_all answers for many accounts and leaves out the ones it cannot" do
    known   = Account.new(id: 1, name: "Accountancy fees")
    unknown = Account.new(id: 2, name: "Bank account")

    found = TaxCategoryGuesser.for_scheme("gb_self_employment").guess_all([ known, unknown ])

    assert_equal({ 1 => "professional_fees" }, found)
  end
end
