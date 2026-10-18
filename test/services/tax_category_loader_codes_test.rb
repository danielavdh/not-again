# frozen_string_literal: true

require "test_helper"
require "tempfile"

# The tax_codes: half of a catalogue file. What the loader must refuse, and
# what a refused file must leave untouched.
class TaxCategoryLoaderCodesTest < ActiveSupport::TestCase
  def write_yaml(codes)
    f = Tempfile.new([ "xx_vat", ".yml" ])
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
end
