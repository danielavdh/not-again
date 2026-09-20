require "test_helper"

class AccountTaxTest < ActiveSupport::TestCase
  setup do
    Entity.find_or_create_by!(code: '41') { |e| e.name = 'TestEnt' }
    @parent = Account.create!(code: '504100', name: 'Travel', account_type: :expense)
    @child  = Account.create!(code: '504101', name: 'Trains', account_type: :expense, parent: @parent)
  end

  # A parent groups accounts the way the owner thinks about the business, a
  # category the way the authority does, and the two need not coincide — so an
  # account's category is its own or it has none.
  test "a category is not inherited from the parent" do
    @parent.update!(tax_scheme: 'gb_self_employment', tax_category_key: 'travel_costs')
    assert_nil @child.effective_tax_scheme
    assert_nil @child.effective_tax_category_key
  end

  test "an account's own category is its category" do
    @child.update!(tax_scheme: 'gb_self_employment', tax_category_key: 'other_expenses')
    assert_equal 'gb_self_employment', @child.effective_tax_scheme
    assert_equal 'other_expenses',  @child.effective_tax_category_key
  end

  test "nil when the account carries no category" do
    assert_nil @child.effective_tax_category_key
  end

  test "tax_taggable? requires income or expense AND no children" do
    asset = Account.new(code: '104100', account_type: :asset)
    refute asset.tax_taggable?, "a balance account is never taggable"
    assert @child.tax_taggable?, "a leaf expense account is taggable"
    refute @parent.tax_taggable?, "a parent is never taggable — its children may differ"
  end

  test "effective_tax_category resolves to catalogue" do
    TaxCategory.create!(country_code: 'gb', scheme: 'gb_self_employment', tax_year: 2026,
                        key: 'travel_costs', section: 'expenses', position: 50)
    @child.update!(tax_scheme: 'gb_self_employment', tax_category_key: 'travel_costs')
    tc = @child.effective_tax_category(country_code: 'gb', tax_year: 2026)
    assert_equal 'travel_costs', tc.key
  end
end
