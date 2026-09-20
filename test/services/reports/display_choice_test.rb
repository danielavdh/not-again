# frozen_string_literal: true
require "test_helper"

# Reading the same books at any accepted authority's rates — EUR at the ECB or
# at the BMF's §16(6) monthly average, CHF at ESTV or cross-rated through the
# ECB. The source used to be derived and never offered.
class Reports::DisplayChoiceTest < ActiveSupport::TestCase
  AVAILABLE = %w[GBP EUR USD CHF].freeze

  def parse(value, fallback: "EUR")
    Reports::DisplayChoice.parse(value, available: AVAILABLE, fallback: fallback)
  end

  # The compatibility promise. Every link, bookmark and form in the app already
  # sends ?currency=CHF; if a bare currency stopped working, all of them would
  # break at once.
  test "a bare currency still means the usual source" do
    c = parse("CHF")

    assert_equal "CHF", c.currency
    assert_nil c.source
    assert_nil c.sources, "nil lets tier 1 (or a tax report's country rule) decide, as before"
    assert_equal "CHF", c.to_param
  end

  test "a currency and a source round-trip" do
    c = parse("CHF:estv")

    assert_equal "CHF", c.currency
    assert_equal "estv", c.source
    assert_equal [ "estv" ], c.sources
    assert_equal "CHF:estv", c.to_param
  end

  test "the same currency can be read at more than one authority" do
    assert_equal "ecb",        parse("EUR:ecb").source
    assert_equal "bundesbank", parse("EUR:bundesbank").source
    assert_equal "estv",       parse("CHF:estv").source

    # A cross-rate is not a choice: it is what a report falls back to when the
    # published series cannot reach its period, and the select shows it only
    # once that has happened. Asking for it by URL is not offering it.
    assert_nil parse("CHF:ecb").source, "the ECB publishes no franc series"
  end

  # This reads a URL parameter, so it may not be trusted to name anything.
  test "a source that cannot reach the currency is refused" do
    assert_nil parse("EUR:hmrc").source, "HMRC is GBP-based and is not the euro fallback"
    assert_nil parse("CHF:nonsense").source
    assert_equal "CHF", parse("CHF:nonsense").currency, "the currency still stands"
  end

  test "an unknown currency falls back" do
    assert_equal "EUR", parse("XXX").currency
    assert_equal "GBP", parse("XXX", fallback: "GBP").currency
    assert_equal "EUR", parse(nil).currency
    assert_equal "EUR", parse("").currency
  end

  # Half of a refused request is not a request. Without this, "XXX:bundesbank"
  # fell back to EUR and quietly KEPT the Bundesbank — a source the reader did
  # not choose, for a currency they did not choose.
  test "a rejected currency takes its source with it" do
    c = parse("XXX:bundesbank")

    assert_equal "EUR", c.currency
    assert_nil c.source
    assert_equal "EUR", c.to_param
  end

  test "case does not matter" do
    assert_equal "CHF", parse("chf:estv").currency
    assert_equal "estv", parse("chf:estv").source
  end

  # THE LANDING BUG. Every option's value is "CURRENCY:source", but on landing
  # there is no ?currency= at all, so to_param is a bare "EUR" — which matches
  # no option. A browser given a selected value it cannot find shows the FIRST
  # option instead: the column read EUR while the select said "GBP (HMRC)". It
  # corrected itself the moment anything was chosen, because the URL then
  # carried the canonical form, which is exactly why it looked like a rendering
  # fluke.
  test "the select is always given a value that matches an option" do
    options = RateSourceConfig.display_options(AVAILABLE).map(&:last)

    [ nil, "", "EUR", "GBP", "CHF", "CHF:estv", "XXX" ].each do |param|
      choice = parse(param)
      assert_includes options, choice.to_option,
                      "landing with #{param.inspect} gives the select a value it cannot match"
    end
  end

  test "to_option names the source actually in use, to_param stays short for URLs" do
    assert_equal "CHF:estv", parse("CHF").to_option, "ESTV is the franc series"
    assert_equal "CHF",     parse("CHF").to_param,  "URLs keep the short form"

    assert_equal "CHF:estv", parse("CHF:estv").to_option
    assert_equal "CHF:estv", parse("CHF:estv").to_param
  end

  # ---- grouping ----

  # <optgroup> rather than a styled divider: the browser draws the heading and
  # the rule itself, it needs no CSS, and a screen reader announces the grouping
  # instead of skipping a decorative line.
  LABELS = { in_use: "In use", others: "Others" }.freeze

  def grouped(currencies)
    Reports::DisplayChoice.grouped_options(currencies, labels: LABELS)
  end

  test "used currencies are grouped apart from the rest" do
    result = grouped(AVAILABLE)

    assert_kind_of Hash, result
    assert_equal [ "In use", "Others" ], result.keys, "used first"
    assert result["In use"].map(&:last).all? { |v| v.start_with?(*Currency.used_codes.to_a) }
  end

  # An optgroup containing everything is a heading that divides nothing.
  test "one group only is returned flat" do
    only_used = Currency.used_codes.to_a & AVAILABLE
    skip "fixtures have no used currencies" if only_used.empty?

    assert_kind_of Array, grouped(only_used), "all used - no grouping to show"
    assert_kind_of Array, grouped(%w[XXX]),   "none used - likewise"
  end

  test "grouping loses no option" do
    result = grouped(AVAILABLE)
    flat   = result.is_a?(Hash) ? result.values.flatten(1) : result

    assert_equal RateSourceConfig.display_options(AVAILABLE).sort, flat.sort,
                 "every option survives the split"
  end

  # ---- the options offered ----

  test "every currency is offered at each source that can reach it" do
    options = RateSourceConfig.display_options(AVAILABLE)
    values  = options.map(&:last)

    assert_includes values, "EUR:ecb"
    assert_includes values, "EUR:bundesbank"
    assert_includes values, "GBP:hmrc"
    assert_includes values, "CHF:estv"
    assert_includes values, "USD:ecb",  "the base of no source at all"

    # The fallback belongs only where tier 1 is actually cross-rating. Sterling
    # reads HMRC, so "GBP (ECB)" named a figure the ECB has never published —
    # reachable only by inverting its euro series.
    assert_not_includes values, "GBP:ecb", "the ECB publishes no sterling series"
  end

  test "the tier 1 answer heads each currency's list" do
    options = RateSourceConfig.display_options(AVAILABLE)

    %w[GBP EUR USD CHF].each do |currency|
      first = options.map(&:last).find { |v| v.start_with?("#{currency}:") }
      assert_equal "#{currency}:#{ExchangeRate.source_for(currency)}", first,
                   "the default for #{currency} must be offered first"
    end
  end

  # Every option offered must survive being parsed back — otherwise the dropdown
  # can produce a value the app then silently discards.
  test "every offered option parses back to itself" do
    RateSourceConfig.display_options(AVAILABLE).each do |_label, value|
      assert_equal value, parse(value).to_param, "#{value} did not round-trip"
    end
  end

  # "EUR (Bundesbank)" does not fit the column header; BMF is also the name a
  # German user is looking for, since the BMF is what publishes the figure.
  test "the report dropdown uses the short label" do
    labels = RateSourceConfig.display_options([ "EUR" ]).map(&:first)

    assert_includes labels, "EUR (BMF)"
    assert_not_includes labels, "EUR (Bundesbank)"
    assert_equal "Bundesbank", RateSourceConfig.label_for("bundesbank"),
                 "the full label still names the feed we actually call"
  end

  # The two screens are ONE JOURNEY. A report says it cannot convert and sends
  # you to the rates page to fetch — where you arrive looking for the BMF and
  # find a dropdown offering only "Bundesbank". Naming both closes that gap
  # without widening the report column to hold the long name.
  test "the fetch control names both, so the journey connects" do
    labels = Rates::FetchOptions.call.to_h.keys

    assert labels.any? { |l| l.include?("BMF") },
           "a report that cannot convert sends you to the rates page looking for " \
           "the BMF — arriving at a list naming only the Bundesbank breaks the journey"
  end

  # And the authority is what you actually recognise. You know who your tax boss
  # is; you may well not know which central bank they point at.
  test "the fetch control names the authority that accepts each feed" do
    labels = Rates::FetchOptions.call.to_h.keys

    assert_includes labels, "ELSTER (BMF)"
    assert_includes labels, "HMRC", "the authority IS the publisher here, so it is named once"
    assert_not_includes labels, "HMRC (HMRC)"
  end
end
