# frozen_string_literal: true
require "test_helper"

# Prefer the right source, fall back to the available one, and SAY WHICH WAS
# USED.
#
# Pointing CHF at ESTV alone — which is the correct Swiss series — made every
# pre-August Swiss report raise RateUnavailable, for rates that were in the
# database the whole time under `ecb`: once ESTV was the chosen source the ECB
# rows were never consulted.
#
# ESTV serves the CURRENT MONTH ONLY. Its feed ignores every date parameter, so
# its history cannot be backfilled, ever. It is right and it cannot reach.
class CrossSourceFallbackTest < ActiveSupport::TestCase
  setup do
    @august = Date.new(2026, 8, 1)
    @march  = Date.new(2026, 3, 1)

    # ESTV holds August only — its real-world shape.
    rate("estv", @august, 0.92)
    # The ECB holds both, as it holds years of everything.
    rate("ecb", @august, 0.95)
    rate("ecb", @march,  0.97)
  end

  def rate(source, month, value)
    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "CHF", source: source, rate: value,
      effective_date: month, valid_from: month, valid_to: month.end_of_month
    )
  end

  def translator(date, sources)
    ExchangeRate::Translator.new("CHF", date, sources: sources)
  end

  test "the preferred source wins where it reaches" do
    t = translator(@august, %w[estv ecb])

    assert_equal 92, t.translate(100, "EUR")
    assert_equal "estv", t.source_used_for("EUR")
  end

  # The case that raised in production.
  test "the fallback answers where the preferred source has nothing" do
    t = translator(@march, %w[estv ecb])

    assert_equal 97, t.translate(100, "EUR"),
                 "March must convert at the ECB rate, not raise"
    assert_equal "ecb", t.source_used_for("EUR")
  end

  # A fallback nobody can see is worse than no fallback: the figure is
  # defensible
  # only if you can say which published rate produced it.
  test "which source answered is visible per date" do
    t = translator(@august, %w[estv ecb])

    assert_equal "estv", t.source_used_for("EUR", on: Date.new(2026, 8, 15))
    assert_equal [ "estv" ], t.sources_used([ "EUR" ])
  end

  test "order decides, not the database" do
    assert_equal 95, translator(@august, %w[ecb estv]).translate(100, "EUR")
    assert_equal 92, translator(@august, %w[estv ecb]).translate(100, "EUR")
  end

  # Tier 1 hands the translator ONE source, base-matching, exactly as before —
  # so no ordinary report changes. What differs for francs is which one it
  # prefers: the Swiss series, not the euro one. Whether a report can actually
  # use it is decided before the translator is built, by
  # ExchangeRate.source_for_span, because only a report knows its own period.
  test "with no sources given it is tier 1's single answer" do
    t = ExchangeRate::Translator.new("CHF", @august)

    assert_equal "estv", t.source, "francs prefer the Swiss series"
  end

  # An entity's own elected rate outranks the whole preference list. It is the
  # business's declared choice, and Switzerland is exactly where that applies.
  test "an entity's own rate beats every accepted source" do
    entity = Entity.create!(code: "96", name: "Swiss group", active: true)
    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "CHF", source: "manual", rate: 0.90,
      effective_date: @august, valid_from: @august, valid_to: @august.end_of_month,
      entity_id: entity.id
    )

    t = ExchangeRate::Translator.new("CHF", @august, entity, sources: %w[estv ecb])

    assert_equal 90, t.translate(100, "EUR")
    assert_equal "manual", t.source_used_for("EUR")
  end

  # One query for the whole preference list, not one per source. A fallback that
  # almost never fires must not cost a round trip on every report.
  test "all accepted sources are read in one query" do
    t = translator(@august, %w[estv ecb])

    queries = 0
    counter = ->(_n, _s, _f, _i, payload) {
      queries += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ])
    }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      t.translate(100, "EUR")
    end

    assert_operator queries, :<=, 3,
                    "expected one span query (plus the owned-rate EXISTS check), got #{queries}"
  end
end
