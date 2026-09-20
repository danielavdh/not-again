require "test_helper"

# N+1 guard. Two kinds of assertion, and the second is the one that matters:
#
# 1. No single SQL statement SHAPE runs more than a few times in one request.
# Repetition of one shape with different ids is what an N+1 looks like, and it
# shows even on the small fixture set.
# 2. The query count does not GROW when the data does. A page that costs the
# same for 16 accounts and 56 is not looping; a page that costs more is.
#
# When a page legitimately gets more expensive, raise its budget deliberately
# and say why. Do not delete the test.
class QueryBudgetTest < ActionDispatch::IntegrationTest
  # Ceilings with headroom over what the pages cost today. Tightening them is
  # always welcome; raising one is a decision.
  BUDGETS = {
    "accounts#index"        => 20,
    "dashboard#index"       => 25,
    "journal_entries#index" => 15,
    "receipts#index"        => 20,
    # +1 each on 2026-08-26, deliberately: ExchangeRate.covers_span? asks once
    # per report whether the preferred rate series reaches every month of the
    # period, which is what lets a report use one series throughout instead of
    # stitching two together. One grouped query, not one per month.
    "reports#trial_balance" => 21,
    "reports#profit_loss"   => 21,
    # +1 on 2026-09-07: the balance sheet now computes the FX translation
    # variance too (M4), the same one-query lookup the other two already run.
    "reports#balance_sheet" => 20,
    "admins#index"          => 15,
    # The authorised-access table renders a row per (coadmin, shared entity).
    "admins#show"           => 14
  }.freeze

  # Above this, one statement shape in one request is a loop until proven
  # otherwise. Three allows for a filter's count + page + a legitimate re-ask.
  MAX_REPEATS_OF_ONE_SHAPE = 4

  # CurrencyConfig.available is memoised per process, so whichever request runs
  # first pays its one query — which made the baseline look more expensive than
  # the comparison. Prime it.
  def count_queries
    CurrencyConfig.available
    sql = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:name].to_s =~ /SCHEMA|TRANSACTION/
      next if payload[:sql].to_s =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i
      sql << payload[:sql].to_s
    end
    yield
    sql
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  # Statement text with every id and placeholder blanked, so the same query with
  # different arguments collapses to one shape.
  def shapes(sql)
    sql.map { |q| q.gsub(/\$\d+/, "?").gsub(/\b\d+\b/, "?").gsub(/\s+/, " ").strip }
  end

  def assert_within_budget(label, sql)
    budget = BUDGETS.fetch(label)
    assert_operator sql.size, :<=, budget,
      "#{label} ran #{sql.size} queries, budget #{budget}"

    worst_shape, worst_count = shapes(sql).tally.max_by { |_s, n| n }
    assert_operator worst_count, :<=, MAX_REPEATS_OF_ONE_SHAPE,
      "#{label} ran one statement shape #{worst_count} times — that is a loop:\n  #{worst_shape&.first(200)}"
  end

  # --- shape + ceiling, on the fixture data --------------------------------

  test "the accounts pages stay within budget" do
    sign_in_as(admins(:two))

    assert_within_budget "accounts#index",        count_queries { get accounts_url(locale: :en) }
    assert_within_budget "dashboard#index",       count_queries { get dashboard_url(locale: :en) }
    assert_within_budget "journal_entries#index", count_queries { get journal_entries_url(locale: :en) }
    assert_within_budget "receipts#index",        count_queries { get receipts_url(locale: :en) }
    assert_within_budget "reports#trial_balance", count_queries { get trial_balance_reports_url(locale: :en) }
    assert_within_budget "reports#profit_loss",   count_queries { get profit_loss_reports_url(locale: :en) }
    assert_within_budget "reports#balance_sheet", count_queries { get balance_sheet_reports_url(locale: :en) }
  end

  test "sudo, who sees every entity, stays within the same budget" do
    sign_in_as(admins(:sudo))

    assert_within_budget "accounts#index",  count_queries { get accounts_url(locale: :en) }
    assert_within_budget "dashboard#index", count_queries { get dashboard_url(locale: :en) }
  end

  test "the admins list stays within budget" do
    sign_in_as(admins(:sudo))
    assert_within_budget "admins#index", count_queries { get admins_url(locale: :en) }
    assert_within_budget "admins#show",  count_queries { get admin_url(admins(:sudo), locale: :en) }
  end

  test "the admin page stays within budget for a full-access admin" do
    sign_in_as(admins(:one))
    assert_within_budget "admins#show", count_queries { get admin_url(admins(:one), locale: :en) }
  end

  test "admins#show costs the same with ten more coadmins on the same entities" do
    sign_in_as(admins(:one))

    before = count_queries { get admin_url(admins(:one), locale: :en) }.size

    # Two links each, on both of admin one's entities, so every added coadmin
    # is two more rows on the authorised-access table.
    10.times do |i|
      coadmin = Admin.create!(
        username: "bulk_coadmin_#{i}", email_address: "bulk#{i}@example.com",
        password: "password", terms_agreed_version: Admin::TERMS_VERSION,
        terms_agreed_at: Time.current, claimed_at: Time.current
      )
      AdminEntity.create!(admin: coadmin, entity: entities(:personal), access_level: :read_only)
      AdminEntity.create!(admin: coadmin, entity: entities(:spouse),   access_level: :upload_receipts)
    end

    after = count_queries { get admin_url(admins(:one), locale: :en) }.size

    assert_equal before, after,
      "admins#show went from #{before} to #{after} queries when 10 coadmins were added — it is looping over rows"
  end

  # --- the real test: cost must not follow data ----------------------------

  test "accounts#index costs the same with forty more accounts" do
    sign_in_as(admins(:two))

    before = count_queries { get accounts_url(locale: :en) }.size

    # Entity 10 is admin two's. Half of them get a posting, so the
    # has-postings/has-children lookups have something to find.
    40.times do |i|
      account = Account.create!(
        code: format("510%03d", 100 + i), name: "Bulk expense #{i}",
        account_type: :expense, currency: "GBP", active: true
      )
      next unless i.even?
      JournalEntry.create!(
        entry_date: Date.current,
        postings_attributes: [
          { account_id: account.id, amount: 100, currency: "GBP", entry_type: :debit },
          { account_id: accounts(:bank_gbp).id, amount: 100, currency: "GBP", entry_type: :credit }
        ]
      )
    end

    after = count_queries { get accounts_url(locale: :en) }.size

    assert_equal before, after,
      "accounts#index went from #{before} to #{after} queries when 40 accounts were added — it is looping over rows"
  end

  # Compared between two populated states rather than against the bare fixtures:
  # going from no report groups to some legitimately adds one preload query, and
  # that is a constant, not a loop. Five more businesses against fifteen more is
  # the honest comparison — a per-entity query would show as +10.
  test "the dashboard costs the same for five businesses as for fifteen" do
    sign_in_as(admins(:two))

    add_entities(5, from: 20)
    five = count_queries { get dashboard_url(locale: :en) }.size

    add_entities(10, from: 30)
    fifteen = count_queries { get dashboard_url(locale: :en) }.size

    assert_equal five, fifteen,
      "the dashboard went from #{five} to #{fifteen} queries when 10 more businesses were added — it is looping over entities"
  end

  # Each with a report group, because that is what a real business has and the
  # partial loops over those too.
  def add_entities(count, from:)
    count.times do |i|
      entity = Entity.create!(code: format("%02d", from + i), name: "Extra #{from + i}", active: true)
      AdminEntity.create!(admin: admins(:two), entity: entity, access_level: :full_access)
      ReportGroup.create!(name: "Group #{from + i}", entity: entity)
    end
  end
end
