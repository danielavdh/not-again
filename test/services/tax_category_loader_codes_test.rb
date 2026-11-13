# frozen_string_literal: true

require "test_helper"
require "tempfile"

# The tax_codes: half of a catalogue file. What the loader must refuse, and
# what a refused file must leave untouched.
class TaxCategoryLoaderCodesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Held until teardown: a Tempfile nobody references is deleted by the garbage
  # collector, and a path handed back alone can point at nothing by the time
  # the loader opens it.
  teardown { @tempfiles&.each(&:close!) }

  def write_yaml(codes)
    f = Tempfile.new([ "xx_vat", ".yml" ])
    (@tempfiles ||= []) << f
    f.write(<<~YML)
      country_code: xx
      scheme: vat
      tax_year: 2026
      kind: vat
      categories:
        - key: box_a
          export_column: "A"
          position: 10
        - key: box_b
          export_column: "B"
          position: 20
      tax_codes:
      #{codes.lines.map { |l| "  " + l }.join}
    YML
    f.flush
    f.path
  end

  CODE = <<~YML
    - key: sale
      rate_bps: 2000
      direction: output
      valid_from: "2011-01-04"
      net_category_key: box_a
      tax_category_key: box_b
      position: 10
  YML

  # Two rows of one key in force on the same day resolve by id — the older
  # rate, silently. A rate change is a valid_to AND a valid_from.
  test "a later row of a key is refused while the earlier one is still open" do
    path = write_yaml(CODE + <<~YML)
      - key: sale
        rate_bps: 2500
        direction: output
        valid_from: "2026-06-01"
        net_category_key: box_a
        tax_category_key: box_b
        position: 10
    YML

    error = assert_raises(RuntimeError) { TaxCategoryLoader.call(path) }
    assert_match(/still in force/, error.message)
  end

  test "a closed earlier row followed by a later one is accepted" do
    path = write_yaml(CODE.sub(%(valid_from: "2011-01-04"), %(valid_from: "2011-01-04"\n  valid_to: "2026-05-31")) + <<~YML)
      - key: sale
        rate_bps: 2500
        direction: output
        valid_from: "2026-06-01"
        net_category_key: box_a
        tax_category_key: box_b
        position: 10
    YML

    assert_equal 2, TaxCategoryLoader.call(path).codes
    assert_equal 2000, TaxCode.resolve(scheme: "xx_vat", key: "sale", on: Date.new(2026, 5, 1)).rate_bps
    assert_equal 2500, TaxCode.resolve(scheme: "xx_vat", key: "sale", on: Date.new(2026, 7, 1)).rate_bps
  end

  # One file, one transaction: a refused file used to leave the boxes updated,
  # the removal email queued and the doomed code still there.
  test "a refused file changes nothing" do
    TaxCategoryLoader.call(write_yaml(CODE))
    before = [ TaxCategory.where(scheme: "xx_vat").count, TaxCode.where(scheme: "xx_vat").count ]

    bad = write_yaml(CODE.sub("sale", "sale_renamed") + <<~YML)
      - key: broken
        rate_bps: 2000
        direction: output
        valid_from: "2011-01-04"
        flat_rate: sometimes
        position: 20
    YML
    assert_raises(RuntimeError) { TaxCategoryLoader.call(bad) }

    assert_equal before, [ TaxCategory.where(scheme: "xx_vat").count, TaxCode.where(scheme: "xx_vat").count ]
    assert TaxCode.exists?(scheme: "xx_vat", key: "sale"), "the old code survives the refused rename"
  end

  test "flat_rate takes only the three treatments" do
    path = write_yaml(CODE.sub("position: 10", "flat_rate: sometimes\n  position: 10"))
    error = assert_raises(RuntimeError) { TaxCategoryLoader.call(path) }
    assert_match(/flat_rate/, error.message)
  end

  # A remembered default is a form prefill, not history. It used to hold the
  # foreign key that made the prune crash halfway.
  test "pruning a code clears the accounts that remembered it as their default" do
    TaxCategoryLoader.call(write_yaml(CODE))
    code = TaxCode.find_by!(scheme: "xx_vat", key: "sale")
    accounts(:income_sales).update_column(:default_tax_code_id, code.id)

    TaxCategoryLoader.call(write_yaml(CODE.sub("key: sale", "key: sale_renamed")))

    assert_nil accounts(:income_sales).reload.default_tax_code_id
    assert_not TaxCode.exists?(id: code.id)
  end

  # A row is key + valid_from, so every one of these leaves a row the file no
  # longer declares. They used to fail the load, and with it every deploy.

  def sale_row(rate: 2000, from:, to: nil)
    <<~YML
      - key: sale
        rate_bps: #{rate}
        direction: output
        valid_from: "#{from}"
        #{to ? %(valid_to: "#{to}") : ""}
        net_category_key: box_a
        tax_category_key: box_b
        position: 10
    YML
  end

  # A posting of a real entry, carrying the code row, dated as given.
  def booked(code, on:, posting: postings(:deposit_income))
    posting.update_column(:tax_code_id, code.id)
    posting.journal_entry.update_column(:entry_date, on)
    posting
  end

  def sale_rows = TaxCode.where(scheme: "xx_vat", key: "sale").order(:valid_from)

  test "a corrected start date moves the entries to the corrected row and drops the old one" do
    TaxCategoryLoader.call(write_yaml(sale_row(from: "2021-01-01")))
    old = sale_rows.first
    posting = booked(old, on: Date.new(2022, 3, 1))

    TaxCategoryLoader.call(write_yaml(sale_row(from: "2010-01-01")))

    corrected = sale_rows.sole
    assert_equal Date.new(2010, 1, 1), corrected.valid_from
    assert_equal corrected.id, posting.reload.tax_code_id
    assert_not TaxCode.exists?(id: old.id)
  end

  test "a period split in two sends each entry to the row covering its date" do
    TaxCategoryLoader.call(write_yaml(sale_row(from: "2011-01-04")))
    old = sale_rows.first
    early = booked(old, on: Date.new(2015, 6, 1), posting: postings(:deposit_income))
    late  = booked(old, on: Date.new(2024, 6, 1), posting: postings(:withdrawal_expense))

    TaxCategoryLoader.call(write_yaml(sale_row(from: "2010-01-01", to: "2019-12-31") +
                                      sale_row(from: "2020-01-01")))

    first, second = sale_rows.to_a
    assert_equal first.id,  early.reload.tax_code_id
    assert_equal second.id, late.reload.tax_code_id
    assert_not TaxCode.exists?(id: old.id)
  end

  test "an entry the new row would book at another rate keeps the old row, retired, and its bookkeepers are told once" do
    TaxCategoryLoader.call(write_yaml(sale_row(from: "2011-01-04")))
    old = sale_rows.first
    posting = booked(old, on: Date.new(2015, 6, 1))

    assert_enqueued_with(job: TaxCodeRetirementNotificationJob, args: [ { tax_code_ids: [ old.id ] } ]) do
      TaxCategoryLoader.call(write_yaml(sale_row(rate: 2500, from: "2010-01-01")))
    end

    assert_equal old.id, posting.reload.tax_code_id, "the entry is not touched"
    assert old.reload.retired_at, "kept, and marked"
    assert_equal 2500, TaxCode.resolve(scheme: "xx_vat", key: "sale", on: Date.new(2015, 6, 1)).rate_bps,
                 "a new pick never finds the retired row"

    assert_no_enqueued_jobs(only: TaxCodeRetirementNotificationJob) do
      TaxCategoryLoader.call(write_yaml(sale_row(rate: 2500, from: "2010-01-01")))
    end
    assert TaxCode.exists?(id: old.id)
  end

  test "an entry no new row covers keeps the old row too" do
    TaxCategoryLoader.call(write_yaml(sale_row(from: "2011-01-04")))
    old = sale_rows.first
    posting = booked(old, on: Date.new(2015, 6, 1))

    TaxCategoryLoader.call(write_yaml(sale_row(from: "2016-01-01")))

    assert_equal old.id, posting.reload.tax_code_id
    assert old.reload.retired_at
  end

  test "once its entries have a current code, the retired row goes on the next load" do
    TaxCategoryLoader.call(write_yaml(sale_row(from: "2011-01-04")))
    old = sale_rows.first
    posting = booked(old, on: Date.new(2015, 6, 1))
    yaml = write_yaml(sale_row(rate: 2500, from: "2010-01-01"))
    TaxCategoryLoader.call(yaml)

    posting.update_column(:tax_code_id, TaxCode.resolve(scheme: "xx_vat", key: "sale", on: Date.new(2015, 6, 1)).id)
    TaxCategoryLoader.call(yaml)

    assert_not TaxCode.exists?(id: old.id)
  end

  test "a retired row the file declares again is current again" do
    TaxCategoryLoader.call(write_yaml(sale_row(from: "2011-01-04")))
    old = sale_rows.first
    posting = booked(old, on: Date.new(2015, 6, 1))
    TaxCategoryLoader.call(write_yaml(sale_row(rate: 2500, from: "2010-01-01")))
    assert old.reload.retired_at

    TaxCategoryLoader.call(write_yaml(sale_row(from: "2011-01-04")))

    assert_nil old.reload.retired_at
    assert_equal old.id, posting.reload.tax_code_id
    assert_equal [ old.id ], sale_rows.ids, "the 2500 row had no entries and is gone"
  end

  test "a remembered default moves to today's row of the same key" do
    TaxCategoryLoader.call(write_yaml(sale_row(from: "2021-01-01")))
    accounts(:income_sales).update_column(:default_tax_code_id, sale_rows.first.id)

    TaxCategoryLoader.call(write_yaml(sale_row(from: "2010-01-01")))

    assert_equal sale_rows.sole.id, accounts(:income_sales).reload.default_tax_code_id
  end

  test "the code dropdown leaves a retired row out, unless the entry already carries it" do
    TaxCategoryLoader.call(write_yaml(sale_row(from: "2011-01-04")))
    old = sale_rows.first
    booked(old, on: Date.new(2015, 6, 1))
    TaxCategoryLoader.call(write_yaml(sale_row(rate: 2500, from: "2010-01-01")))

    ids = ->(options) { options.flat_map { |_, rows| rows.map { |row| row[1] } } }
    on  = Date.new(2015, 6, 1)
    assert_not_includes ids.(TaxCode.options_for(schemes: "xx_vat", on: on)), old.id
    assert_includes     ids.(TaxCode.options_for(schemes: "xx_vat", on: on, keep: [ old.id ])), old.id
  end
end
