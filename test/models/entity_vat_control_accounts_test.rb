# frozen_string_literal: true

require "test_helper"

# The control accounts belong to the REGISTRATION. Subscribing to a VAT scheme
# is what brings them into the chart, so no entry ever has to — and none is left
# behind by an entry that was then refused.
class EntityVatControlAccountsTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @entity = entities(:family_biz)
  end

  def control_accounts
    Account.vat_accounts.for_entity_codes([ @entity.code ]).where(tax_scheme: "gb_vat")
  end

  test "subscribing to a VAT scheme puts both control accounts in the chart" do
    assert_equal 0, control_accounts.count

    @entity.update!(tax_schemes: [ "gb_vat" ])

    assert_equal %w[input output], control_accounts.map(&:vat_role).sort
  end

  test "the pair is announced once and not again" do
    @entity.update!(tax_schemes: [ "gb_vat" ])
    assert_equal 2, @entity.created_vat_accounts.size

    @entity.update!(tax_schemes: [ "gb_vat", "gb_self_employment" ])

    assert_empty @entity.created_vat_accounts, "the pair already existed"
    assert_equal 2, control_accounts.count
  end

  test "an income-tax scheme brings no control accounts" do
    @entity.update!(tax_schemes: [ "gb_self_employment" ])

    assert_equal 0, Account.vat_accounts.for_entity_codes([ @entity.code ]).count
  end

  test "unsubscribing takes the unused pair back out" do
    @entity.update!(tax_schemes: [ "gb_vat" ])
    assert_equal 2, control_accounts.count

    @entity.update!(tax_schemes: [])

    assert_equal 0, control_accounts.count
  end

  # Both or neither: half a pair would leave a return reading one side of a
  # registration and inventing the other.
  test "a pair with VAT already posted to it survives unsubscribing" do
    @entity.update!(tax_schemes: [ "gb_vat" ])
    post_a_purchase

    @entity.update!(tax_schemes: [])

    assert_equal 2, control_accounts.count,
                 "nothing was posted to the output side, but the pair stays whole"
  end

  # Once a scheme has been used it can never be fully deleted, only hidden:
  # the VAT in the pair belongs to a year the business did file. Subscribing
  # again brings the SAME accounts back, so that year's return still finds it.
  test "a used pair is hidden on unsubscribing and the same pair comes back on subscribing again" do
    @entity.update!(tax_schemes: [ "gb_vat" ])
    post_a_purchase
    ids = control_accounts.order(:id).pluck(:id)

    @entity.update!(tax_schemes: [])
    assert_equal [ false, false ], control_accounts.order(:id).pluck(:active), "hidden"
    assert_equal [ "gb_vat", "gb_vat" ], control_accounts.pluck(:tax_scheme), "but still the scheme's"

    @entity.update!(tax_schemes: [ "gb_vat" ])
    assert_equal ids, control_accounts.order(:id).pluck(:id), "the same two, no third"
    assert_equal [ true, true ], control_accounts.order(:id).pluck(:active)
  end

  # The Ruby rule checks, then inserts; two saves arriving together both pass
  # the check. The database holds the line: one LIVE control account per
  # entity, scheme and role.
  test "the database refuses a second live control account for the same role" do
    @entity.update!(tax_schemes: [ "gb_vat" ])
    live = control_accounts.find_by(vat_role: :input)
    twin = Account.new(live.attributes.except("id").merge("code" => "110990", "name" => "twin"))

    assert_raises(ActiveRecord::RecordNotUnique) { twin.save(validate: false) }
  end

  test "unsubscribing one scheme leaves another scheme's accounts alone" do
    @entity.update!(tax_schemes: [ "gb_vat", "gb_self_employment" ])

    @entity.update!(tax_schemes: [ "gb_vat" ])

    assert_equal 2, control_accounts.count
  end

  private

    # The bank form's own sequence: derive, then sum the rest into the bank leg.
    def post_a_purchase
      code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: Date.new(2026, 5, 1))
      je = JournalEntry.new(entry_date: Date.new(2026, 5, 1), memo: "vat")
      je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                        amount: 12_000, tax_code_id: code.id)
      je.derive_tax_legs
      je.postings.build(account: accounts(:bank_gbp), entry_type: :credit,
                        amount: 12_000, currency: "GBP")
      je.save!
    end
end
