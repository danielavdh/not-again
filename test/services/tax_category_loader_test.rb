# frozen_string_literal: true
require "test_helper"
require "tempfile"

class TaxCategoryLoaderTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def write_yaml(content)
    f = Tempfile.new(["cat", ".yml"])
    f.write(content); f.flush
    f.path
  end

  test "loads a minimal valid YAML" do
    path = write_yaml(<<~YML)
      country_code: GB
      scheme: self_employment
      tax_year: 2026
      categories:
        - key: sales_income
          section: income
          position: 10
    YML
    count = TaxCategoryLoader.call(path)
    assert_equal 1, count
    # Loader downcases country_code, so resolve with lowercase
    tc = TaxCategory.resolve(country_code: "gb", scheme: "gb_self_employment",
                             year: 2026, key: "sales_income")
    assert tc
    assert_equal "income", tc.section
  end

  # The loader must REFUSE a file rather than store a word nothing downstream
  # can interpret.
  #
  # With `section` as free text, a country writing its own word for "income"
  # produced a CSV with every row present, every subtotal right, and a NET line
  # of zero — the figures fell through to "other", which totals nothing. Nothing
  # raised, and the same zero reached the submission archive.
  test "a section in the country's own language is refused, not stored" do
    path = write_yaml(<<~YML)
      country_code: RO
      scheme: ro_pit
      tax_year: 2026
      categories:
        - key: venituri_din_chirii
          label: "Venituri din cedarea folosinței bunurilor"
          section: venituri
          position: 10
    YML
    error = assert_raises(RuntimeError) { TaxCategoryLoader.call(path) }
    assert_match(/venituri/, error.message)
    assert_match(/income, expenses, other/, error.message)
    assert_match(/label/, error.message, "must point the contributor at where the form's own word belongs")
    assert_equal 0, TaxCategory.where(country_code: "ro").count
  end

  test "api_section is held to the same vocabulary as section" do
    path = write_yaml(<<~YML)
      country_code: RO
      scheme: ro_pit
      tax_year: 2026
      categories:
        - key: impozit_retinut
          section: other
          api_section: venituri
          position: 10
    YML
    assert_raises(RuntimeError) { TaxCategoryLoader.call(path) }
    assert_equal 0, TaxCategory.where(country_code: "ro").count
  end

  # Blank is legitimate: a row that is on the form but drives no total at all.
  test "a row may omit its section" do
    path = write_yaml(<<~YML)
      country_code: RO
      scheme: ro_pit
      tax_year: 2026
      categories:
        - { key: informativ, position: 10 }
    YML
    assert_equal 1, TaxCategoryLoader.call(path)
    assert_nil TaxCategory.find_by(country_code: "ro", key: "informativ").section
  end

  test "is idempotent" do
    path = write_yaml(<<~YML)
      country_code: GB
      scheme: self_employment
      tax_year: 2026
      categories:
        - { key: sales_income, section: income, position: 10 }
    YML
    TaxCategoryLoader.call(path)
    TaxCategoryLoader.call(path)
    # Loader stores lowercase country_code
    assert_equal 1, TaxCategory.where(country_code: "gb", scheme: "gb_self_employment").count
  end

  test "stores the label as written, in the form's own language" do
    path = write_yaml(<<~YML)
      country_code: DE
      scheme: vermietung
      tax_year: 2026
      categories:
        - key: umgelegte_kosten
          label: "Umgelegte Kosten"
          export_column: "52"
          section: expenses
          position: 10
    YML
    TaxCategoryLoader.call(path)
    tc = TaxCategory.find_by(country_code: "de", scheme: "de_vermietung", key: "umgelegte_kosten")
    assert_equal "Umgelegte Kosten", tc.label
    assert_equal "52", tc.reference
    assert_equal "52 — Umgelegte Kosten", tc.display_name
  end

  # The file IS the catalogue. A key dropped from it must leave the database
  # too: an account tagged with a category that no longer exists is dropped
  # silently by Reports::TaxCsv, so the figure would vanish without an error.
  test "removes rows that the file no longer declares" do
    two = write_yaml(<<~YML)
      country_code: DE
      scheme: euer
      tax_year: 2026
      categories:
        - { key: betriebseinnahmen_umsatzsteuerpflichtig, section: income, position: 10 }
        - { key: betriebseinnahmen_ermaessigt,            section: income, position: 20 }
    YML
    TaxCategoryLoader.call(two)
    assert_equal 2, TaxCategory.where(country_code: "de", scheme: "de_euer", tax_year: 2026).count

    one = write_yaml(<<~YML)
      country_code: DE
      scheme: euer
      tax_year: 2026
      categories:
        - { key: betriebseinnahmen_umsatzsteuerpflichtig, section: income, position: 10 }
    YML
    TaxCategoryLoader.call(one)
    remaining = TaxCategory.where(country_code: "de", scheme: "de_euer", tax_year: 2026)
    assert_equal %w[betriebseinnahmen_umsatzsteuerpflichtig], remaining.pluck(:key)
  end

  # Removing a key is the one catalogue change that can strand somebody's
  # accounts, and it does so in silence: the account keeps a non-blank
  # tax_category_key, so it never joins the "needs tagging" list, and the export
  # and the HMRC payload both skip a category they cannot resolve. So the loader
  # hands the removed KEYS to a job rather than merely counting them.
  test "removing a key enqueues the notification, with the keys" do
    two = write_yaml(<<~YML)
      country_code: DE
      scheme: euer
      tax_year: 2026
      categories:
        - { key: keeper,  section: income, position: 10 }
        - { key: dropped, section: income, position: 20 }
    YML
    TaxCategoryLoader.call(two)

    one = write_yaml(<<~YML)
      country_code: DE
      scheme: euer
      tax_year: 2026
      categories:
        - { key: keeper, section: income, position: 10 }
    YML

    assert_enqueued_with(job: TaxCategoryRemovalNotificationJob) do
      TaxCategoryLoader.call(one)
    end

    job = enqueued_jobs.last
    args = job[:args].first.deep_symbolize_keys
    assert_equal %w[dropped], args[:removed_keys]
    assert_equal "de_euer", args[:scheme]
    assert_equal 2026, args[:tax_year]
  end

  test "a load that removes nothing enqueues nothing" do
    path = write_yaml(<<~YML)
      country_code: DE
      scheme: euer
      tax_year: 2026
      categories:
        - { key: keeper, section: income, position: 10 }
    YML
    TaxCategoryLoader.call(path)

    assert_no_enqueued_jobs(only: TaxCategoryRemovalNotificationJob) do
      TaxCategoryLoader.call(path) # idempotent reload
    end
  end

  # Pruning is scoped to the file's own country, scheme and year — loading one
  # catalogue must not empty another.
  test "removing rows leaves other schemes and years alone" do
    other = write_yaml(<<~YML)
      country_code: DE
      scheme: vermietung
      tax_year: 2026
      categories:
        - { key: mieteinnahmen, section: income, position: 10 }
    YML
    TaxCategoryLoader.call(other)

    path = write_yaml(<<~YML)
      country_code: DE
      scheme: euer
      tax_year: 2026
      categories:
        - { key: waren_rohstoffe, section: expenses, position: 10 }
    YML
    TaxCategoryLoader.call(path)

    assert TaxCategory.exists?(country_code: "de", scheme: "de_vermietung", key: "mieteinnahmen")
  end

  test "rejects duplicate keys within one file" do
    path = write_yaml(<<~YML)
      country_code: GB
      scheme: self_employment
      tax_year: 2026
      categories:
        - { key: x }
        - { key: x }
    YML
    assert_raises(RuntimeError) { TaxCategoryLoader.call(path) }
  end

  test "rejects unknown row keys" do
    path = write_yaml(<<~YML)
      country_code: GB
      scheme: self_employment
      tax_year: 2026
      categories:
        - { key: x, bogus: true }
    YML
    assert_raises(RuntimeError) { TaxCategoryLoader.call(path) }
  end

  test "rejects missing required header" do
    path = write_yaml(<<~YML)
      country_code: GB
      tax_year: 2026
      categories: []
    YML
    assert_raises(RuntimeError) { TaxCategoryLoader.call(path) }
  end
end
