# frozen_string_literal: true
require "test_helper"

# WHICH DAY's rate applies to a transaction.
#
# `date_basis` was declared in db/exchange_rate_rules.yml, documented in its
# header, exposed by RateRuleConfig — and read by nothing at all, so it looked
# like a working feature to anyone who opened the file.
#
# It changes nothing while every source is monthly, because one span covers
# every day of the month and there is no day without a rate. It becomes the
# whole question the moment a DAILY feed arrives, which is what a national
# central bank usually publishes: Romania's BNR quotes every banking day, so a
# transaction on a Saturday, a Sunday or a public holiday has no rate of its own
# and the law has to say which one applies.
class RateDateBasisTest < ActiveSupport::TestCase
  # A daily feed with a weekend hole in it. Friday and Monday are published;
  # Saturday and Sunday are not, because no bank quoted a rate on those days.
  FRIDAY   = Date.new(2026, 8, 7)
  SATURDAY = Date.new(2026, 8, 8)
  SUNDAY   = Date.new(2026, 8, 9)
  MONDAY   = Date.new(2026, 8, 10)

  setup do
    daily(FRIDAY, 5.10)
    daily(MONDAY, 5.30)
  end

  # One day, one span — which is exactly how a daily source is stored, and the
  # reason the span model was chosen over a single date.
  def daily(day, value)
    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "RON", source: "ecb", rate: value,
      effective_date: day, valid_from: day, valid_to: day
    )
  end

  def translator(date, basis)
    ExchangeRate::Translator.new("RON", date, sources: %w[ecb], date_basis: basis)
  end

  test "a published day answers for itself whatever the basis" do
    RateRuleConfig::DATE_BASES.each do |basis|
      assert_equal 5.10, translator(FRIDAY, basis).rate("EUR", on: FRIDAY)
      assert_equal 5.30, translator(FRIDAY, basis).rate("EUR", on: MONDAY)
    end
  end

  # The default, and what the app did before this was wired up. A missing rate
  # is a missing rate: the whole point of RateUnavailable was replacing a silent
  # 1.0, and quietly reaching backwards would put the silence back.
  test "on the transaction-date basis an unpublished day has no rate" do
    t = translator(FRIDAY, RateRuleConfig::TRANSACTION_DATE)
    assert_raises(ExchangeRate::RateUnavailable) { t.rate("EUR", on: SATURDAY) }
  end

  test "on the preceding-publication basis a weekend takes Friday's rate" do
    t = translator(FRIDAY, RateRuleConfig::PRECEDING_PUBLICATION)
    assert_equal 5.10, t.rate("EUR", on: SATURDAY)
    assert_equal 5.10, t.rate("EUR", on: SUNDAY), "Sunday reaches back past Saturday to Friday"
  end

  # The rule is PRECEDING, and that word is load-bearing. Monday's rate was
  # published after Saturday's transaction happened, so it cannot be the rate
  # that applied to it, however much closer it is in days.
  test "it never reaches forward to a rate published after the transaction" do
    t = translator(FRIDAY, RateRuleConfig::PRECEDING_PUBLICATION)
    assert_equal 5.10, t.rate("EUR", on: SATURDAY),
                 "Saturday must take Friday's 5.10, not Monday's 5.30"
  end

  # A posting on 1 January must reach 31 December. The translator loads one
  # month of spans in a single query, so this only works because the window is
  # widened when the basis asks for it — the bug would have been invisible in
  # any test that stayed inside one month.
  test "the reach crosses a month boundary" do
    dec31 = Date.new(2025, 12, 31)
    jan1  = Date.new(2026, 1, 1)
    daily(dec31, 4.95)

    t = translator(jan1, RateRuleConfig::PRECEDING_PUBLICATION)
    assert_equal 4.95, t.rate("EUR", on: jan1),
                 "New Year's Day must reach back to the last publication of the old year"
  end

  # Nothing published before the date at all. There is no honest answer, and an
  # error is the honest failure.
  test "it raises rather than inventing a rate when nothing precedes the date" do
    t = translator(FRIDAY, RateRuleConfig::PRECEDING_PUBLICATION)
    assert_raises(ExchangeRate::RateUnavailable) do
      t.rate("EUR", on: Date.new(2026, 8, 1))
    end
  end

  # The reported source must be the one that actually answered. A report that
  # says which series produced a figure and then uses another is worse than one
  # that says nothing.
  test "the source that answered is reported for a reached-back day" do
    t = translator(FRIDAY, RateRuleConfig::PRECEDING_PUBLICATION)
    assert_equal "ecb", t.source_used_for("EUR", on: SATURDAY)
  end

  # --- where the basis comes from ------------------------------------------

  test "an ordinary report is never bound to a date basis" do
    assert_equal RateRuleConfig::TRANSACTION_DATE,
                 ExchangeRate.date_basis_for_scheme(nil)
  end

  test "a submission takes its basis from the scheme's country" do
    RateRuleConfig.stub(:date_basis_for, RateRuleConfig::PRECEDING_PUBLICATION) do
      assert_equal RateRuleConfig::PRECEDING_PUBLICATION,
                   ExchangeRate.date_basis_for_scheme("gb_property")
    end
  end

  # A typo in the rules file must not silently change how figures are dated.
  # Unknown reads as the default, and the guard test in rate_rule_config_test
  # stops it reaching the repository in the first place.
  test "an unrecognised basis falls back to the transaction date" do
    RateRuleConfig.stub(:rule, { "date_basis" => "whenever_really" }) do
      assert_equal RateRuleConfig::TRANSACTION_DATE,
                   RateRuleConfig.date_basis_for("ro")
    end
  end
end
