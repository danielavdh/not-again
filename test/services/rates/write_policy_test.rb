# frozen_string_literal: true
require "test_helper"

# Two rules, and no third category:
#
# fetched  =>  the shared series every entity reads  =>  sudo
# typed    =>  one business's own rate               =>  write access to that
# entity
#
# Protecting only `fetch_rates` left every other action open to any admin with
# accounts write access, so anyone could edit or delete the shared ECB and HMRC
# rows every entity's reports rest on — silently moving another business's
# figures.
class Rates::WritePolicyTest < ActiveSupport::TestCase
  setup do
    @sudo  = admins(:sudo)
    @admin = admins(:one)
    @mine  = Entity.find_by(code: @admin.writable_entity_codes.first)
    @month = Date.new(2026, 3, 1)
  end

  def rate(source: "ecb", entity: nil, from: "EUR", to: "GBP")
    ExchangeRate.new(source: source, from_currency: from, to_currency: to,
                          rate: 0.85, effective_date: @month,
                          valid_from: @month, valid_to: @month.end_of_month,
                          entity_id: entity&.id)
  end

  # ---- the shared series ----

  test "an ordinary admin may not touch a fetched rate" do
    assert_not Rates::WritePolicy.writable?(rate, @admin),
               "the shared series must not be editable by any admin"
  end

  # A typed rate is never global, so a period the app cannot reach gets filled
  # per entity like everything else typed.
  #
  # Letting an admin type a GLOBAL rate wherever nothing could fetch one —
  # before a publisher's archive began, where a source served only the current
  # month, or where it did not carry that currency — was three computed
  # conditions, and each buggy version passed its own tests.
  test "not even for a period nothing could ever fetch" do
    ancient = rate(source: "hmrc", from: "GBP", to: "EUR")
    ancient.valid_from = Date.new(2018, 7, 1)
    ancient.valid_to   = Date.new(2018, 7, 31)

    assert_not Rates::WritePolicy.writable?(ancient, @admin),
               "a global row is the shared series whatever its date"
    assert_equal :shared_series, Rates::WritePolicy.refusal_reason(ancient, @admin)
  end

  test "sudo may" do
    assert Rates::WritePolicy.writable?(rate, @sudo)
    assert_nil Rates::WritePolicy.refusal_reason(rate, @sudo)
  end

  test "nobody at all when there is no admin" do
    assert_not Rates::WritePolicy.writable?(rate, nil)
  end

  # ---- a business's own rate ----

  test "an admin may write a rate for an entity they can write" do
    skip "no writable entity in fixtures" unless @mine

    assert Rates::WritePolicy.writable?(rate(source: "manual", entity: @mine), @admin)
  end

  test "but not for an entity they cannot" do
    other = Entity.create!(code: "97", name: "Not theirs", active: true)
    r = rate(source: "manual", entity: other)

    assert_not Rates::WritePolicy.writable?(r, @admin)
    assert_equal :no_entity_access, Rates::WritePolicy.refusal_reason(r, @admin)
  end

  test "an entity that no longer exists is writable by nobody but sudo" do
    r = rate(source: "manual")
    r.entity_id = 999_999

    assert_not Rates::WritePolicy.writable?(r, @admin)
  end

  # ---- the list path ----

  # The index renders 25 rows, and the two paths encode the same rule twice.
  # This is what stops them drifting: an earlier pair disagreed on real rows
  # while both passed their own tests.
  test "the bulk map agrees with the per-row answer" do
    skip "no writable entity in fixtures" unless @mine

    rows = [
      ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", source: "ecb",
                                rate: 0.85, effective_date: @month,
                                valid_from: @month, valid_to: @month.end_of_month),
      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", source: "manual",
                                rate: 1.1, effective_date: @month, entity_id: @mine.id,
                                valid_from: @month, valid_to: @month.end_of_month)
    ]

    bulk = Rates::WritePolicy.writable_map(rows, @admin)
    rows.each do |r|
      assert_equal Rates::WritePolicy.writable?(r, @admin), bulk[r.id],
                   "#{r.source} #{r.from_currency}->#{r.to_currency}"
    end
    assert_equal [ false, true ], rows.map { |r| bulk[r.id] },
                 "the shared row is refused, the entity's own is allowed"
  end

  test "sudo sees everything as writable" do
    row = rate.tap(&:save!)
    assert_equal({ row.id => true }, Rates::WritePolicy.writable_map([ row ], @sudo))
  end

  test "an empty list asks nothing" do
    assert_empty Rates::WritePolicy.writable_map([], @admin)
  end
end
