# frozen_string_literal: true
require "test_helper"

# CurrencyConfig's two weaknesses are exactly the kind that never surface in
# English: a symbol it does not know about, and a thousands separator it has
# never seen. Both returned nil, which the forms show as an empty field rather
# than an error.
class CurrencyConfigTest < ActiveSupport::TestCase
  # NBSP -> plain, so the readable assertions can skip \u00A0; the
  # "non-breaking" test proves the real output uses NBSP.
  def plain(str) = str.gsub("\u00A0", " ")

  # ---- parsing ----

  test "reads the formats English-speaking users type" do
    assert_equal 123_456, CurrencyConfig.parse_to_cents("1234.56")
    assert_equal 123_456, CurrencyConfig.parse_to_cents("1,234.56")
    assert_equal 123_456, CurrencyConfig.parse_to_cents("£1,234.56")
  end

  test "reads the formats everyone else types" do
    assert_equal 123_456, CurrencyConfig.parse_to_cents("1.234,56"),   "German"
    assert_equal 123_456, CurrencyConfig.parse_to_cents("1'234.56"),   "Swiss"
    assert_equal 123_456, CurrencyConfig.parse_to_cents("1 234,56"),   "space as thousands separator"
    assert_equal 123_456, CurrencyConfig.parse_to_cents("1 234,56"), "non-breaking space"
    assert_equal 123_456, CurrencyConfig.parse_to_cents("1 234,56"), "narrow no-break space"
  end

  # Stripping only £ € $ meant CHF — a currency the app has always supported —
  # failed to parse the moment anyone pasted a formatted amount rather than
  # typing digits.
  test "strips every symbol and code the app knows about" do
    assert_equal 123_456, CurrencyConfig.parse_to_cents("CHF 1'234.56")
    assert_equal 123_456, CurrencyConfig.parse_to_cents("€1.234,56")
    assert_equal  50_000, CurrencyConfig.parse_to_cents("USD 500")
  end

  # And currencies the app does NOT know about yet, so that pasting works before
  # anyone remembers to add the symbol to SYMBOLS.
  test "strips currency markers it has never heard of" do
    assert_equal 123_456, CurrencyConfig.parse_to_cents("1234,56 лв."), "Bulgarian lev"
    assert_equal 123_456, CurrencyConfig.parse_to_cents("1 234,56 ₴"),  "Ukrainian hryvnia"
    assert_equal   9_999, CurrencyConfig.parse_to_cents("zł 99,99"),    "Polish złoty"
    assert_equal  50_000, CurrencyConfig.parse_to_cents("500 UAH"),     "bare ISO code"
  end

  # Stripping is at the ENDS only. Junk in the middle is not a number with
  # decoration around it, it is a typo, and it must still fail.
  test "still refuses things that are not numbers" do
    assert_nil CurrencyConfig.parse_to_cents("abc")
    assert_nil CurrencyConfig.parse_to_cents("12abc34")
    assert_nil CurrencyConfig.parse_to_cents("")
    assert_nil CurrencyConfig.parse_to_cents(nil)
  end

  # A heuristic recognising a comma decimal only when followed by EXACTLY two
  # digits means a European typing one decimal place — the ordinary way to write
  # half of something — stores ten times the amount, and a bare-thousands
  # "1.234" stores 1.23. The rule is the one every money parser uses: the
  # rightmost of '.' and ',' is the decimal point.
  test "one decimal place is read as a decimal, not a thousands separator" do
    assert_equal   150, CurrencyConfig.parse_to_cents("1,5"),     "European one euro fifty"
    assert_equal   150, CurrencyConfig.parse_to_cents("1.5"),     "English one pound fifty"
    assert_equal 123_450, CurrencyConfig.parse_to_cents("1.234,5"), "European, grouped, one decimal"
    assert_equal 123_450, CurrencyConfig.parse_to_cents("1,234.5"), "English, grouped, one decimal"
  end

  # "1.234" / "1,234": one separator, three trailing digits, genuinely
  # ambiguous. Money is not written to three decimal places, so it is read as a
  # thousands separator — 1234, not 1.234. Same answer whichever separator, so
  # the result does not depend on guessing the writer's locale.
  test "a lone separator before three digits is thousands grouping" do
    assert_equal 123_400, CurrencyConfig.parse_to_cents("1.234")
    assert_equal 123_400, CurrencyConfig.parse_to_cents("1,234")
    assert_equal 1_234_567_00, CurrencyConfig.parse_to_cents("1.234.567")
    assert_equal 1_234_567_00, CurrencyConfig.parse_to_cents("1,234,567")
  end

  # Grouping that is not actually groups of three is malformed. Better a blank
  # field the user re-types than a confident wrong number booked silently.
  test "refuses a separator layout that is neither decimal nor clean grouping" do
    assert_nil CurrencyConfig.parse_to_cents("1,234,56")
    assert_nil CurrencyConfig.parse_to_cents("1.23.456")
  end

  test "keeps the sign" do
    assert_equal(-123_456, CurrencyConfig.parse_to_cents("-1 234,56"))
    assert_equal(-150,     CurrencyConfig.parse_to_cents("-1,5"))
  end

  # The seam: the JS running total (scripts/utils.js parseAmountToCents) and the
  # Ruby that stores the value must read a string the same way.
  # test/system/amount_input_test.rb drives the SAME rows through a real browser
  # and form — keep the two lists in step.
  PARSE_PARITY_ROWS = {
    "1234.56"      => 123_456,
    "1,234.56"     => 123_456,
    "1.234,56"     => 123_456,
    "1 234,56"     => 123_456,
    "1'234.56"     => 123_456,
    "1,5"          => 150,
    "1.5"          => 150,
    "10"           => 1_000,
    "1000"         => 100_000,
    "1.234"        => 123_400,   # lone separator + 3 digits -> grouping
    "1,234"        => 123_400,
    "1.005"        => 100_500,   # same rule: "005" is a group of three
    "1,5055"       => 151,       # unambiguous decimal, rounds half up
    "0,99"         => 99,
    "-1.234,56"    => -123_456,
    "1.234.567,89" => 123_456_789,
    "1,234,567.89" => 123_456_789,
    "1,234,56"     => nil,       # grouping that is not groups of three
    "12abc34"      => nil
  }.freeze

  test "parses every row of the shared JS/Ruby parity table" do
    PARSE_PARITY_ROWS.each do |input, cents|
      # Two rows expect nil — "unreadable", not a value. assert_equal nil is
      # deprecated and fails outright in Minitest 6.
      if cents.nil?
        assert_nil CurrencyConfig.parse_to_cents(input), input.inspect
      else
        assert_equal cents, CurrencyConfig.parse_to_cents(input), input.inspect
      end
    end
  end

  # ---- formatting ----

  # No admin on Current, so every format_cents below falls to the UI language's
  # default: en → "uk", de/es → "de", nl → "at". Every space inside a formatted
  # amount is non-breaking so it cannot wrap onto a second line.
  test "the language default decides grouping, decimal and symbol side" do
    assert_equal "£1,234.56",  CurrencyConfig.format_cents(123_456, "GBP", locale: :en)   # uk
    assert_equal "1.234,56 £", plain(CurrencyConfig.format_cents(123_456, "GBP", locale: :de))   # de: after
    assert_equal "€ 1.234,56", plain(CurrencyConfig.format_cents(123_456, "EUR", locale: :nl))   # at: before + space
  end

  # An explicit number-format choice overrides the language — grouping AND which
  # side the symbol sits. A German who picks the Swiss format gets the franc in
  # front, not behind.
  test "the admin's number-format choice wins over the language" do
    Current.number_format = "ch"
    assert_equal "CHF 1'234.56", plain(CurrencyConfig.format_cents(123_456, "CHF", locale: :de))

    Current.number_format = "fr"
    assert_equal "1 234,56 €", plain(CurrencyConfig.format_cents(123_456, "EUR", locale: :en))
  ensure
    Current.number_format = nil
  end

  test "every space inside a formatted amount is non-breaking" do
    Current.number_format = "fr" # space-grouped + symbol-after: the worst case
    refute_includes CurrencyConfig.format_cents(1_234_567_89, "EUR"), " ", "a plain space would wrap"
    refute_includes CurrencyConfig.format_display(1_234_567.89), " "
  ensure
    Current.number_format = nil
  end

  # Whatever a screen shows an amount as, typing that string straight back must
  # give the same cents — in every language, because parse_to_cents is locale-
  # independent and format_cents is not.
  test "round-trips what it formats, in every language and both signs" do
    %i[en de es nl].each do |loc|
      %w[GBP EUR USD CHF].each do |code|
        [123_456, -123_456, 5, 100_000_00].each do |cents|
          shown = CurrencyConfig.format_cents(cents, code, locale: loc)
          assert_equal cents, CurrencyConfig.parse_to_cents(shown),
                       "#{code} #{cents} shown as #{shown.inspect} (#{loc}) did not survive"
        end
      end
    end
  end

  test "round-trips format_display too" do
    %i[en de es nl].each do |loc|
      [123_456, -7, 999_999_99].each do |cents|
        shown = CurrencyConfig.format_display(cents / 100.0, locale: loc)
        assert_equal cents, CurrencyConfig.parse_to_cents(shown), "#{shown.inspect} (#{loc})"
      end
    end
  end
end
