# frozen_string_literal: true
require "test_helper"

class TaxCategoryAutoAssignerRetiredTest < ActiveSupport::TestCase
  # When an account already holds any tax_category_key — including one since
  # removed from the catalogue — the auto-assigner skips it rather than
  # overwriting it.
  test "does not clobber an existing tax_category_key" do
    entity = entities(:family_biz)
    entity.update_columns(tax_schemes: [ "gb_self_employment" ])

    account = accounts(:income_sales)
    account.update_columns(tax_category_key: "retired_nonexistent_key")

    assert_nothing_raised do
      TaxCategoryAutoAssigner.call(entity_code: entity.code, dry_run: false)
    end

    account.reload
    assert_equal "retired_nonexistent_key", account.tax_category_key,
      "Existing keys should be preserved, not overwritten"
  ensure
    account.update_columns(tax_category_key: nil)
  end

  test "raises ArgumentError for unknown entity code" do
    assert_raises(ArgumentError) do
      TaxCategoryAutoAssigner.call(entity_code: "99", dry_run: true)
    end
  end

  # A guess needs exactly one country, and the country comes from the schemes.
  test "raises ArgumentError when the entity has no schemes to guess from" do
    entity = entities(:standalone)
    entity.update_columns(tax_schemes: [])
    assert_raises(ArgumentError) do
      TaxCategoryAutoAssigner.call(entity_code: entity.code, dry_run: true)
    end
  end
end
