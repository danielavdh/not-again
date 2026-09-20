# frozen_string_literal: true
require "test_helper"

# A CONSOLIDATED family report covers several entities at once, and each one's
# own elected rate must apply to its own accounts: the rule does not stop at the
# family boundary.
#
# Applying owned rates only when exactly ONE entity was selected meant a family
# report quietly used the published series for everyone — and families are real
# here, since a Swiss entity sits in one.
class ConsolidatedOwnedRatesTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(admins(:sudo))

    @family = EntityGroup.create!(name: "Family")
    @owns   = Entity.create!(code: "81", name: "Has own rate", active: true,
                                  entity_group_id: @family.id)
    @plain  = Entity.create!(code: "82", name: "Published only", active: true,
                                  entity_group_id: @family.id)

    @month = Date.new(2026, 3, 1)

    # What everyone reads unless they have said otherwise. A GBP report reads
    # HMRC, whose base IS sterling, so the published row is GBP → EUR and the
    # EUR → GBP direction is derived by inverting it: 1 / 1.25 = 0.80.
    ExchangeRate.create!(from_currency: "GBP", to_currency: "EUR", source: "hmrc",
                              rate: 1.25, effective_date: @month,
                              valid_from: @month, valid_to: @month.end_of_month)
  end

  def own_rate_for(entity, value)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", source: "manual",
                              rate: value, effective_date: @month, entity_id: entity.id,
                              note: "board minute", valid_from: @month, valid_to: @month.end_of_month)
  end

  def account_in(entity, digit)
    Account.create!(code: "#{digit}#{entity.code}001",
                         name: "acct #{entity.code}",
                         account_type: digit == "1" ? :asset : :income,
                         currency: digit == "1" ? "EUR" : nil)
  end

  test "each entity's own rate applies to its own accounts in one family report" do
    own_rate_for(@owns, 0.50)

    t = ExchangeRate.translator("GBP", date: @month)

    assert_equal 50, t.translate(100, "EUR", on: @month + 5, entity_id: @owns.id),
                 "the entity with its own rate must use it"
    assert_equal 80, t.translate(100, "EUR", on: @month + 5, entity_id: @plain.id),
                 "the entity without one must use the published rate"
    assert_equal 80, t.translate(100, "EUR", on: @month + 5),
                 "and with no entity named, the published rate"
  end

  # The efficiency claim, pinned: a family with NO hand-entered rates asks one
  # EXISTS question for the whole report and never queries per entity.
  test "no owned rates anywhere costs one extra question, not one per entity" do
    t = ExchangeRate.translator("GBP", date: @month)
    t.translate(100, "EUR", on: @month + 1, entity_id: @owns.id)

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].to_s == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      10.times do |i|
        t.translate(100, "EUR", on: @month + 2, entity_id: (i.even? ? @owns.id : @plain.id))
      end
    end

    assert_equal 0, queries, "everything needed was already cached after the first call"
  end
end
