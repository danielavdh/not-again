# frozen_string_literal: true
require "test_helper"

# The validity span and its guards. Every one of these was verified against the
# real schema before being written down — two failed the first time, and the
# failures were real rather than test bugs.
class ExchangeRateSpanTest < ActiveSupport::TestCase
  setup do
    @attrs = { from_currency: "EUR", to_currency: "SEK", rate: 11.2,
               effective_date: Date.new(2030, 3, 1),
               valid_from: Date.new(2030, 3, 1), valid_to: Date.new(2030, 3, 31) }
    @base = ExchangeRate.create!(@attrs.merge(source: "ecb"))
  end

  # The invariant the span lookup rests on: "the row covering this date" must
  # have exactly one answer, and Postgres promises no order between two matches.
  test "an overlapping span from the same source is refused by the database" do
    assert_raises(ActiveRecord::StatementInvalid) do
      ExchangeRate.create!(@attrs.merge(source: "ecb", rate: 1.23,
        valid_from: Date.new(2030, 3, 10), valid_to: Date.new(2030, 3, 12)))
    end
  end

  # The case that silently passed on the first attempt. An exclusion constraint
  # conflicts only when EVERY operator is true, and `NULL = NULL` is unknown —
  # so a bare `entity_id WITH =` never fired for public rates, which is all of
  # them. The constraint uses COALESCE(entity_id, 0).
  test "the overlap guard works for PUBLIC rates, where the owner is NULL" do
    assert_nil @base.entity_id, "this test is meaningless unless the owner is NULL"
    assert_raises(ActiveRecord::StatementInvalid) do
      ExchangeRate.create!(@attrs.merge(source: "ecb", rate: 1.23,
        valid_from: Date.new(2030, 3, 5), valid_to: Date.new(2030, 3, 6)))
    end
  end

  # Two publishers may quote the same pair for the same month and disagree. The
  # ECB and the Bundesbank both publish against EUR — that is not a duplicate,
  # it is the entire reason the registry exists.
  test "a second SOURCE may publish the same pair over the same span" do
    assert_difference -> { ExchangeRate.count }, 1 do
      ExchangeRate.create!(@attrs.merge(source: "bundesbank", rate: 11.19))
    end
  end

  # A Swiss group's internal rate, a Hungarian taxpayer's chosen bank, a German
  # Tageskurs evidenced by a bank statement. Nobody publishes these, and they
  # legitimately sit beside the public rate for the same span.
  test "a taxpayer's OWN rate may sit alongside the public one" do
    assert_difference -> { ExchangeRate.count }, 1 do
      ExchangeRate.create!(@attrs.merge(source: "manual", rate: 11.5,
        entity_id: entities(:family_biz).id, note: "group rate, board minute 2030-01"))
    end
  end

  test "a non-overlapping span from the same source is fine" do
    assert_difference -> { ExchangeRate.count }, 1 do
      ExchangeRate.create!(@attrs.merge(source: "ecb", rate: 11.3,
        valid_from: Date.new(2030, 4, 1), valid_to: Date.new(2030, 4, 30)))
    end
  end

  test "a span cannot end before it starts" do
    assert_raises(ActiveRecord::StatementInvalid) do
      ExchangeRate.create!(@attrs.merge(source: "nbu", rate: 1.0,
        valid_from: Date.new(2030, 5, 31), valid_to: Date.new(2030, 5, 1)))
    end
  end

  # ---- span containment as THE lookup ----

  # The point of the whole exercise: the same query serves a rate that is valid
  # for one day and a rate that is valid for a month, without being told which.
  test "a one-day span is found on its day and nowhere else" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "NOK", source: "norges",
      rate: 11.7, effective_date: Date.new(2030, 6, 12),
      valid_from: Date.new(2030, 6, 12), valid_to: Date.new(2030, 6, 12))

    assert_equal 11.7, ExchangeRate.find_rate_on("EUR", "NOK", Date.new(2030, 6, 12), "norges")
    assert_nil ExchangeRate.find_rate_on("EUR", "NOK", Date.new(2030, 6, 13), "norges"),
               "a daily rate must not leak into the next day"
    assert_nil ExchangeRate.find_rate_on("EUR", "NOK", Date.new(2030, 6, 11), "norges"),
               "a daily rate must not leak into the previous day"
  end

  test "a month span answers for every day inside it" do
    [1, 15, 31].each do |day|
      assert_equal 11.2, ExchangeRate.find_rate_on("EUR", "SEK", Date.new(2030, 3, day), "ecb"),
                   "the month's rate should answer for the #{day}th"
    end
    assert_nil ExchangeRate.find_rate_on("EUR", "SEK", Date.new(2030, 4, 1), "ecb")
  end

  # Feeds publish one direction only — the ECB quotes EUR->USD, never USD->EUR.
  test "the inverse is derived, and respects the same span" do
    assert_in_delta (1.0 / 11.2),
                    ExchangeRate.find_rate_on("SEK", "EUR", Date.new(2030, 3, 15), "ecb"),
                    0.000001
    assert_nil ExchangeRate.find_rate_on("SEK", "EUR", Date.new(2030, 4, 15), "ecb")
  end

  # ---- how a period reads on screen ----

  # ECB rows carry a month-END effective_date, so July's rate displayed as "31
  # July 2026" — which reads like a rate for that one day rather than the figure
  # governing the whole month. The span says what it actually means.
  test "a whole month reads as the month" do
    r = ExchangeRate.new(valid_from: Date.new(2026, 7, 1), valid_to: Date.new(2026, 7, 31))
    assert_equal "July 2026", r.period_label
  end

  test "a single day reads as that day" do
    r = ExchangeRate.new(valid_from: Date.new(2026, 6, 12), valid_to: Date.new(2026, 6, 12))
    assert_equal "12 Jun 2026", r.period_label
  end

  # Switzerland's average runs from the 25th to the 24th, so it belongs to no
  # calendar month and must not be labelled as one.
  test "a window that is not a calendar month reads as a range" do
    r = ExchangeRate.new(valid_from: Date.new(2026, 6, 25), valid_to: Date.new(2026, 7, 24))
    assert_equal "25 Jun 2026 – 24 Jul 2026", r.period_label
  end

  # ---- per-day translation, the point of step 3b ----

  # With a DAILY source, two postings in the same month must convert at their
  # own days' rates. A translator holding one rate per month would have every
  # day of the month share one figure — silently, and looking entirely normal.
  #
  # This is what German VAT needs for a currency the BMF does not publish: the
  # Tageskurs, the rate on the day.
  test "a daily source gives each day its own rate, within one month" do
    [ [ 3, 10.0 ], [ 10, 11.0 ], [ 17, 12.0 ] ].each do |day, rate|
      ExchangeRate.create!(from_currency: "EUR", to_currency: "NOK", source: "nbu",
        rate: rate, effective_date: Date.new(2030, 9, day),
        valid_from: Date.new(2030, 9, day), valid_to: Date.new(2030, 9, day))
    end

    # `sources:` rather than poking @source, which is what this line used to do
    # back when the translator held exactly one and there was no other way in.
    t = ExchangeRate::Translator.new("NOK", Date.new(2030, 9, 1), sources: [ "nbu" ])

    assert_equal 1_000, t.translate(100, "EUR", on: Date.new(2030, 9, 3))
    assert_equal 1_100, t.translate(100, "EUR", on: Date.new(2030, 9, 10))
    assert_equal 1_200, t.translate(100, "EUR", on: Date.new(2030, 9, 17))
  end

  # And the monthly case must be UNCHANGED — every day in the month answers the
  # same, because one span covers all of them. That is what makes the change
  # safe to land while every live source is still monthly.
  test "a monthly source answers identically for every day it covers" do
    t = ExchangeRate::Translator.new("SEK", Date.new(2030, 3, 1))

    [ 1, 15, 31 ].each do |day|
      assert_equal 1_120, t.translate(100, "EUR", on: Date.new(2030, 3, day)),
                   "the #{day}th should use the month's single rate"
    end
  end

  # One query for the month, not one per day — the reason day-level grouping is
  # affordable at all. Two queries: the direct rows and the inverse ones.
  test "resolving many days costs one load, not one per day" do
    t = ExchangeRate::Translator.new("SEK", Date.new(2030, 3, 1))
    t.translate(100, "EUR", on: Date.new(2030, 3, 1))

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].to_s == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      (2..28).each { |d| t.translate(100, "EUR", on: Date.new(2030, 3, d)) }
    end

    assert_equal 0, queries, "the month's spans are cached; days must not re-query"
  end

  # Existing rows were month-END dates for ECB but were USED as the month's
  # rate. Backfilling them as single-day points would have made a posting on the
  # 15th find the previous month — a silent change to every old report.
  test "the backfill turned every existing row into a full month span" do
    ExchangeRate.where.not(source: %w[manual bundesbank nbu]).find_each do |r|
      assert_equal r.valid_from, r.valid_from.beginning_of_month, "#{r.id} does not start a month"
      assert_equal r.valid_to,   r.valid_from.end_of_month,       "#{r.id} does not end its month"
    end
  end
end
