# frozen_string_literal: true
require "test_helper"

# The converted column's header is also where the currency-and-source select
# lives, which makes "when do we show the column" a navigation question as well
# as a presentation one.
class ReportsHelperTest < ActionView::TestCase
  include ReportsHelper
  include FormattingHelper

  # THE DEAD END. Dropping the column on a missing rate is sensible on its own —
  # nobody should read a column of zeros as real figures — but it also removes
  # the select, so choosing a series with no rate for the period leaves the page
  # with no way back except editing the URL by hand.
  #
  # Keeping it is safe because the cells empty themselves: every call site
  # defaults a missing translation to 0, and format_cents_with_currency renders
  # 0 as "".
  test "a missing rate leaves the column standing, so the select survives" do
    @rate_unavailable = ExchangeRate::RateUnavailable.new(
      from_currency: "EUR", to_currency: "CHF", date: Date.new(2026, 3, 1), source: "estv"
    )

    # Two currencies, because that is also when the select is offered, which is
    # precisely the case where losing the column stranded the reader.
    assert translated_column?(%w[EUR GBP], "CHF"),
           "the column must stay: it carries the only control that can change the series"
    assert Reports::CurrencyColumns.selectable?(%w[EUR GBP]),
           "and this is the case that has a select to lose"
  end

  test "and the empty cells really are empty" do
    assert_equal "", format_cents_with_currency(0, "CHF"),
                 "a zero translation renders blank, which is what empties the column"
    assert_equal "", format_cents_with_currency(nil, "CHF")
  end

  # The rule itself is unchanged: a single currency that already IS the display
  # currency has nothing to convert, so no column.
  test "the column is still dropped when it would only repeat itself" do
    assert_not translated_column?(%w[CHF], "CHF")
    assert     translated_column?(%w[EUR GBP], "CHF")
  end

  # Header and colspans read the same method, which is why they cannot drift.
  test "colspan counts the column exactly when the header shows it" do
    assert_equal 1 + 2 + 1, report_colspan(%w[EUR GBP], "CHF")
    assert_equal 1 + 1,     report_colspan(%w[CHF], "CHF")
  end
end
