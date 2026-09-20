# frozen_string_literal: true
require "test_helper"

# "How do we know a rate is needed, and for which currency?" answers itself —
# the postings already say. There is no policy to configure here.
class Rates::GapFinderTest < ActiveSupport::TestCase
  setup do
    @bank     = Account.create!(code: "193001", name: "Bank", account_type: :asset, currency: "GBP")
    @eur_bank = Account.create!(code: "193002", name: "EUR bank", account_type: :asset, currency: "EUR")
    @income   = Account.create!(code: "493001", name: "Fees", account_type: :income)
  end

  # The books must hold more than one currency for anything to need converting —
  # see periods_with_convertible_postings. Most tests here want that true, so it
  # is stated once.
  def make_books_multi_currency
    je = JournalEntry.new(entry_date: Date.new(2026, 1, 5), memo: "eur")
    je.postings.build(account: @income, entry_type: :credit, amount: 100)
    je.postings.build(account: @eur_bank, entry_type: :debit, amount: 100, currency: "EUR")
    je.save!
  end

  def post_on(date, posted: true)
    je = JournalEntry.new(entry_date: date, memo: "x")
    je.postings.build(account: @income, entry_type: :credit, amount: 100)
    je.postings.build(account: @bank, entry_type: :debit, amount: 100, currency: "GBP")
    je.save!

    # Passing `posted: false` to .new does NOT work: journal_entry.rb sets
    # `self.posted = balanced? unless posted_changed?`, and setting false on a
    # new record is not a change, since false is the column default. A balanced
    # entry therefore posts itself, and unposting has to happen after the save.
    je.update_column(:posted, false) unless posted
    je
  end

  # A saved report is what declares a period worth having rates for.
  def report_over(from, to)
    entity = Entity.create!(code: "96", name: "Reported", active: true)
    group  = entity.report_groups.create!(name: "g")
    group.reports.create!(name: "r", start_date: from, end_date: to)
  end

  def rate_for(source, month)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", source: source, rate: 0.85,
                              effective_date: month, valid_from: month, valid_to: month.end_of_month)
  end

  test "a month a saved report covers, with no rate, is a gap" do
    make_books_multi_currency
    report_over(Date.new(2026, 4, 1), Date.new(2026, 4, 30))

    assert_includes Rates::GapFinder.call.map(&:last), Date.new(2026, 4, 1)
  end

  # The case a posting-based rule misses entirely: a report DISPLAYS a month in
  # which nobody happened to post. It still needs a rate, or the column is blank
  # for that month.
  test "a month inside a report but with no postings is still a gap" do
    make_books_multi_currency
    report_over(Date.new(2026, 4, 1), Date.new(2026, 6, 30))

    months = Rates::GapFinder.call.map(&:last)
    assert_includes months, Date.new(2026, 5, 1), "May has no postings but the report shows it"
  end

  test "a month whose rate exists is not a gap" do
    make_books_multi_currency
    report_over(Date.new(2026, 4, 1), Date.new(2026, 4, 30))
    Rates::GapFinder.fillable_sources.each { |s| rate_for(s, Date.new(2026, 4, 1)) }

    assert_not_includes Rates::GapFinder.call.map(&:last), Date.new(2026, 4, 1)
  end

  # The rule lives in Reports::CurrencyColumns: a report showing ONE currency
  # has no translating column at all. But it is per-REPORT, not per-month — a
  # report spanning January (two currencies) and February (one) still converts
  # February. So the test is whether the BOOKS are multi-currency, and then
  # every posted month counts.
  test "a single-currency month still counts when the books use several" do
    make_books_multi_currency
    report_over(Date.new(2026, 5, 1), Date.new(2026, 5, 31))

    assert_includes Rates::GapFinder.call.map(&:last), Date.new(2026, 5, 1)
  end

  # Whether the FEED can serve the past is the question, not what role a source
  # plays.
  #
  # Restricting to "sources a REPORT reads" — display_default plus the fallback
  # — was aimed at ESTV, which serves the current month only, but it caught the
  # BUNDESBANK too. The Bundesbank is month-parameterised and perfectly
  # backfillable, so it sat on a single stored month while the ECB held eight
  # years, and selecting EUR (BMF) on any older report asked for rates nothing
  # had ever fetched.
  test "every source whose history can be fetched is filled" do
    fillable = Rates::GapFinder.fillable_sources

    assert_includes fillable, "bundesbank",
                    "month-parameterised, so its history is fetchable and must be filled"
    assert_includes fillable, "ecb"
    assert_includes fillable, "hmrc"
  end

  # The one real exclusion, and it is a fact about the feed rather than its
  # role: ESTV ignores ?d=, ?month= and ?date= alike. An alarm that cries wolf
  # every night is worse than none.
  test "a source with no route to the past is never asked for it" do
    assert_not_includes Rates::GapFinder.fillable_sources, "estv"
    assert_not RateSourceConfig.backfillable?("estv")
  end

  # No archive reaches before its publisher did. HMRC's Trade Tariff service
  # starts in January 2021; the ECB's goes back to 1999.
  test "periods before a source's archive begins are not reported as gaps" do
    make_books_multi_currency
    report_over(Date.new(2018, 7, 1), Date.new(2018, 7, 31))
    gaps = Rates::GapFinder.call

    assert_not_includes gaps, [ "hmrc", Date.new(2018, 7, 1) ],
                        "HMRC has nothing before 2021 and must not be asked forever"
    assert_includes gaps, [ "ecb", Date.new(2018, 7, 1) ],
                    "the ECB archive does reach 2018, so that IS fillable"
  end

  # Reports run years ahead. Fetching a month that has not happened returns
  # "not published yet" — harmless, but nightly noise for nothing.
  test "months in the future are not chased" do
    make_books_multi_currency
    report_over(Date.current.beginning_of_month, Date.current + 2.years)

    months = Rates::GapFinder.call.map(&:last)
    assert_empty months.select { |m| m > Date.current.end_of_month },
                 "a report reaching into the future must not be fetched ahead of time"
  end

  test "with no saved reports there is nothing to fetch" do
    make_books_multi_currency
    Report.delete_all

    assert_empty Rates::GapFinder.call
  end

  # A business keeping its books in one currency never converts anything — the
  # report has no translating column at all. Fetching rates for it forever would
  # be work nobody asked for.
  test "single-currency books need no rates at all" do
    post_on(Date.new(2026, 7, 10))   # GBP only; no EUR entry
    report_over(Date.new(2026, 7, 1), Date.new(2026, 7, 31))

    assert_empty Rates::GapFinder.call,
                 "books in one currency have nothing to convert"
  end

  # ---- adding a currency ----

  # ADDING A CURRENCY MUST NOT FETCH NOTHING, EVER.
  #
  # When `covered?` meant "this source has SOME rate for this month", every
  # period already held the currencies that existed before the new one, so every
  # period looked covered, the sweep found no gaps, and the screen said "no
  # source — enter rates by hand" while the email said HMRC publishes it. Only
  # the next NEW month would have brought it in, up to a month later.
  test "a period missing a currency the source publishes is a gap" do
    make_books_multi_currency
    report_over(Date.new(2026, 3, 1), Date.new(2026, 3, 31))

    # March holds the old currencies; the latest period also holds UAH — which
    # is
    # the source telling us it carries it.
    store("hmrc", Date.new(2026, 3, 1), %w[EUR USD])
    store("hmrc", Date.new(2026, 4, 1), %w[EUR USD UAH])

    assert_includes Rates::GapFinder.call, [ "hmrc", Date.new(2026, 3, 1) ],
                    "March has no hryvnia and HMRC plainly publishes it"
  end

  # THE OTHER HALF, and the one that stops this crying wolf. The ECB will never
  # carry hryvnia: "which currencies do we SUPPORT" would chase that hole every
  # night forever; "which did this source actually DELIVER" cannot.
  test "a currency the source does not publish is never chased" do
    make_books_multi_currency
    report_over(Date.new(2026, 3, 1), Date.new(2026, 3, 31))

    Currency.create!(code: "UAH", symbol: "₴")
    Currency.expire_cache
    store("ecb", Date.new(2026, 3, 1), %w[EUR USD])
    store("ecb", Date.new(2026, 4, 1), %w[EUR USD])   # no UAH, ever

    assert_not_includes Rates::GapFinder.call, [ "ecb", Date.new(2026, 3, 1) ],
                        "the ECB does not publish it, so it is not a gap"
  end

  # A source we hold nothing for at all is still a gap, as before.
  test "a period with nothing stored is a gap" do
    make_books_multi_currency
    report_over(Date.new(2026, 3, 1), Date.new(2026, 3, 31))

    assert_includes Rates::GapFinder.call.map(&:last), Date.new(2026, 3, 1)
  end

  private

  def store(source, month, currencies)
    currencies.each do |to|
      ExchangeRate.create!(from_currency: "GBP", to_currency: to, source: source,
                                rate: 1.1, effective_date: month,
                                valid_from: month, valid_to: month.end_of_month)
    end
  end
  # DAILY SOURCES
  #
  # A daily source cannot be asked "is this day covered". No publisher quotes on
  # a Saturday, so asking per day would report every weekend and public holiday
  # as a gap, for ever, and nothing would ever fill them — roughly 104 false
  # alarms a year.
  #
  # So a daily source is judged by the MONTH, which is also its fetch unit: one
  # request stores that month's published days, all of them.

  # A one-day span, as a daily feed actually stores.
  def daily_rate_on(day, source: "ecb_daily")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", source: source, rate: 0.85,
                              effective_date: day, valid_from: day, valid_to: day)
  end

  test "a weekend with no published rate is not a gap" do
    make_books_multi_currency
    report_over(Date.new(2026, 1, 1), Date.new(2026, 1, 31))

    # Friday 2nd and Monday 5th January 2026. The 3rd and 4th are a weekend and
    # will never have a rate; the month must still count as covered.
    daily_rate_on(Date.new(2026, 1, 2))
    daily_rate_on(Date.new(2026, 1, 5))

    Rates::GapFinder.stub(:wanted?, true) do
      gaps = Rates::GapFinder.call.select { |source, _| source == "ecb_daily" }
      assert_empty gaps, "a past month holding published days was fetched whole"
    end
  end

  test "a past month with no daily rates at all IS a gap" do
    make_books_multi_currency
    report_over(Date.new(2026, 1, 1), Date.new(2026, 2, 28))
    daily_rate_on(Date.new(2026, 1, 2))   # so the source knows what it publishes

    Rates::GapFinder.stub(:wanted?, true) do
      months = Rates::GapFinder.call.select { |s, _| s == "ecb_daily" }.map(&:last)
      assert_not_includes months, Date.new(2026, 1, 1)
      assert_includes months, Date.new(2026, 2, 1), "February holds nothing and must be fetched"
    end
  end

  # It is still accruing days, and re-fetching is one cheap request that picks
  # up whatever has been published since.
  test "the current month is never covered for a daily source" do
    make_books_multi_currency
    report_over(Date.current.beginning_of_month, Date.current.end_of_month)
    daily_rate_on(Date.current.beginning_of_month)

    Rates::GapFinder.stub(:wanted?, true) do
      months = Rates::GapFinder.call.select { |s, _| s == "ecb_daily" }.map(&:last)
      assert_includes months, Date.current.beginning_of_month
    end
  end

  # FETCH WHAT IS NEEDED, NOT WHAT IS DECLARED

  # Without this, shipping a source means every installation pulls it nightly
  # for ever, for countries it has never heard of. It matters most for a daily
  # source: ~250 periods a year against 12.
  test "a source no rule names and no report displays is never swept" do
    assert_not Rates::GapFinder.wanted?("ecb_daily"),
               "no country accepts it yet, so nothing should fetch it unattended"

    make_books_multi_currency
    report_over(Date.new(2026, 1, 1), Date.new(2026, 1, 31))
    assert_empty Rates::GapFinder.call.select { |s, _| s == "ecb_daily" }
  end

  test "a source a country's rule names IS swept" do
    RateRuleConfig.stub(:all_accepted_sources, %w[ecb_daily]) do
      assert Rates::GapFinder.wanted?("ecb_daily")
    end
  end

  # Tier 1 has to convert before any tax rule exists — an installation with an
  # empty rules file still needs the ECB.
  #
  # WANTED IS NOT THE SAME AS DEFAULT. display_default: false makes the
  # Bundesbank nobody's default, and EUR (BMF) still sits in the currency
  # dropdown of every euro report — so a reader can select it, and if nothing
  # fetched it they get a report with no rates.
  test "a source offered in the report dropdown is wanted even though it defaults to nothing" do
    assert_not RateSourceConfig.display_sources.values.include?("bundesbank"),
               "the Bundesbank is nobody's display default — that is the point of this test"
    assert_includes RateSourceConfig.sources_for_display("EUR"), "bundesbank",
                    "but a euro report can be read at its rates"
    assert Rates::GapFinder.wanted?("bundesbank")
  end

  # The other half: an override naming a tax nobody has written a catalogue for
  # can never fire, so it must not drag its source into the nightly sweep. That
  # is what lets the rules file state a country's law in full — Germany's
  # umsatzsteuer, the Dutch omzetbelasting — at no cost.
  test "an override for a scheme that does not exist wants nothing" do
    assert_not_includes TaxSchemeConfig.all_schemes, "omzetbelasting"
    assert_equal %w[ecb_daily],
                 RateRuleConfig.accepted_sources("nl", scheme: "omzetbelasting"),
                 "the law is stated"
    assert_not_includes RateRuleConfig.all_accepted_sources, "ecb_daily",
                        "and costs nothing until a catalogue for it exists"
  end

  test "a source tier 1 displays through is swept whatever the rules say" do
    RateRuleConfig.stub(:all_accepted_sources, []) do
      assert Rates::GapFinder.wanted?("ecb"), "a report cannot convert without it"
      assert Rates::GapFinder.wanted?("hmrc")
    end
  end

end
