# frozen_string_literal: true
require "test_helper"

# A tax report group is a SAVED QUERY, not a curated set: its accounts are every
# account tagged with its scheme. Nothing is stored that could go stale, which
# is the whole point — what you look at and what gets filed cannot drift.
class TaxReportGroupTest < ActiveSupport::TestCase
  setup do
    @entity = Entity.create!(name: "Tax Report Test", code: "88", active: true, tax_schemes: ["gb_self_employment"])
    @group  = @entity.report_groups.create!(name: "gb-self-employment", tax_scheme: "gb_self_employment")
    @custom = @entity.report_groups.create!(name: "My own report")

    @tagged = Account.create!(code: "588001", name: "Travel", account_type: :expense,
                                   tax_scheme: "gb_self_employment", tax_category_key: "travel_costs")
    @other  = Account.create!(code: "588002", name: "Untagged", account_type: :expense)
  end

  test "tax_report? is simply whether a scheme is set" do
    assert @group.tax_report?
    refute @custom.tax_report?
  end

  test "its accounts are every account tagged with the scheme, nothing stored" do
    assert_equal [ @tagged.id ], @group.account_ids_ordered
    assert_empty @group.report_group_accounts, "membership must not be stored"

    # tagging another account adds it immediately — no sync step
    @other.update!(tax_scheme: "gb_self_employment", tax_category_key: "admin_costs")
    assert_equal [ @tagged.id, @other.id ].sort, @group.account_ids_ordered.sort
  end

  test "untagging an account removes it from the group" do
    @tagged.update!(tax_scheme: nil, tax_category_key: nil)
    assert_empty @group.account_ids_ordered
  end

  test "a scheme's accounts do not leak into another scheme's group" do
    other_group = @entity.report_groups.create!(name: "gb-property", tax_scheme: "gb_property")
    assert_empty other_group.account_ids_ordered
  end

  test "account_ids_ordered falls back to code order for a tax report" do
    @other.update!(tax_scheme: "gb_self_employment", tax_category_key: "admin_costs")
    assert_equal [ @tagged.id, @other.id ], @group.account_ids_ordered, "code order"
  end

  test "the name is declared by the scheme and never translated" do
    assert_equal "GB-self-employment", @group.display_name
    assert_equal "My own report",      @custom.display_name
  end

  test "a tax report totals into its scheme's currency; a custom one does not" do
    assert_equal "GBP", @group.display_currency
    assert_nil @custom.display_currency
  end

  test "only one tax report per entity per scheme" do
    duplicate = @entity.report_groups.build(name: "again", tax_scheme: "gb_self_employment")
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "several custom groups are fine — only tax groups are constrained" do
    assert @entity.report_groups.create(name: "another custom").persisted?
  end

  test "an unknown scheme is rejected" do
    group = @entity.report_groups.build(name: "bad", tax_scheme: "no_such_scheme")
    refute group.valid?
  end

  # Two groups filing the same business overwrite each other at the authority,
  # and neither end says so. The dropdown leaves claimed businesses out; this is
  # the backstop behind it.

  def second_books
    Entity.create!(name: "Second Books", code: "89", active: true,
                        tax_schemes: [ "gb_self_employment" ])
  end

  test "a business already filed by another of the taxpayer's groups is refused" do
    payer = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me")
    @group.update!(taxpayer: payer, business_id: "XBIS111")

    other = second_books.report_groups.create!(name: "gb-self-employment",
                                               tax_scheme: "gb_self_employment")
    other.taxpayer    = payer
    other.business_id = "XBIS111"

    refute other.valid?, "the same business must not be claimed twice"
    assert_includes other.errors.attribute_names, :business_id
  end

  test "but a different business under the same taxpayer is fine" do
    payer = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me")
    @group.update!(taxpayer: payer, business_id: "XBIS111")

    other = second_books.report_groups.create!(name: "gb-self-employment",
                                               tax_scheme: "gb_self_employment")
    assert other.update(taxpayer: payer, business_id: "XBIS222")
  end

  # Two accountants may each hold a taxpayer row for the same client. Those are
  # separate arrangements, and the same identifier under both is not a clash.
  test "the same business under a different taxpayer is not a clash" do
    mine   = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Mine")
    theirs = admins(:two).taxpayers.create!(authority: "hmrc", label: "Theirs")
    @group.update!(taxpayer: mine, business_id: "XBIS111")

    other = second_books.report_groups.create!(name: "gb-self-employment",
                                               tax_scheme: "gb_self_employment")
    assert other.update(taxpayer: theirs, business_id: "XBIS111")
  end

  # Re-saving the group that already holds it must not trip on itself.
  test "a group may keep the business it already has" do
    payer = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me")
    @group.update!(taxpayer: payer, business_id: "XBIS111")
    assert @group.reload.update(business_id: "XBIS111")
  end
end
