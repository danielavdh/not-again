# frozen_string_literal: true

require "test_helper"

# The weekly reminder about VAT code rows the catalogue dropped but entries
# still use. The bookkeepers are emailed once; this is what keeps it visible.
class Maintenance::RetiredTaxCodesCheckTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @code = TaxCode.find_by!(scheme: "gb_vat", key: "sale_standard")
  end

  def check = Maintenance::WeeklyCheck.new(s3: Object.new, backup_bucket: nil).send(:retired_tax_codes)

  test "all clear with no retired rows" do
    assert check.ok
  end

  test "a retired row still in use is a problem, named with its entries" do
    @code.update_column(:retired_at, Time.current)
    postings(:deposit_income).update_column(:tax_code_id, @code.id)

    finding = check
    assert_not finding.ok
    assert_match "sale_standard", finding.detail
    assert_match "1 entry", finding.detail
  end

  test "a retired row nothing uses any more is not a problem" do
    @code.update_column(:retired_at, Time.current)
    assert check.ok
  end
end
