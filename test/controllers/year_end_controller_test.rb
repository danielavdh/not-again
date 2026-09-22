# frozen_string_literal: true

require "test_helper"

class YearEndControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(admins(:sudo)) # sudo sees all entities, including the one built here
    @entity = Entity.create!(name: "YE Test", code: "77", active: true)
    @income = Account.create!(code: "477001", name: "Sales", account_type: :income, active: true)
    @asset  = Account.create!(code: "177001", name: "Bank", account_type: :asset, currency: "GBP", active: true)
    @year   = Date.current.year
  end

  # Pre-existing gap, unrelated to today's work: create_year_end has always
  # archived the period it closes, and this file never cleaned that up.
  teardown do
    FileUtils.rm_rf(uploads_path("archives", "77"))
  end

  # Scoped to this test's entity — fixtures hold closing entries for others.
  def closing_entries_of_entity
    JournalEntry
      .where(closing_entry: true)
      .joins(postings: :account)
      .where("SUBSTRING(accounts.code, 2, 2) = ?", @entity.code)
      .distinct
  end

  def post_income(date, amount: 100)
    je = JournalEntry.new(entry_date: date, posted: true, memo: "t")
    je.postings.build(account: @income, entry_type: :credit, amount: amount)
    je.postings.build(account: @asset, entry_type: :debit, amount: amount, currency: "GBP")
    je.save!
    je
  end

  # --- The only screen: the first-close pattern picker ---

  test "first close shows the pattern picker (which POSTs to create_year_end)" do
    get new_year_end_reports_url(locale: :en, entity_id: @entity.id)
    assert_response :success
    assert_select "form.form_year_end[action*=create_year_end]"
    assert_select "form.form_year_end input[type=radio][name=pattern][value=calendar]"
    assert_select "form.form_year_end input[type=radio][name=pattern][value=uk]"
    assert_select "form.form_year_end input[type=radio][name=pattern][value=other]"
  end

  # Once a pattern is in use the page stops offering the picker and becomes the
  # financial-year page: what the year end currently is, and how to change it.
  test "new_year_end for an already-set-up entity offers the change, not the picker" do
    post_income(Date.new(@year - 1, 6, 1))
    post create_year_end_reports_url(locale: :en, entity_id: @entity.id, pattern: "calendar")
    get new_year_end_reports_url(locale: :en, entity_id: @entity.id)
    assert_response :success
    assert_select "form.form_year_end", count: 0
    assert_select "form[action=?]", change_year_end_reports_path(entity_id: @entity.id)
  end

  test "changing the year end reopens every close, counted in years not entries" do
    post_income(Date.new(@year - 2, 6, 1))
    post_income(Date.new(@year - 1, 6, 1))
    post create_year_end_reports_url(locale: :en, entity_id: @entity.id, pattern: "calendar")
    post create_year_end_reports_url(locale: :en, entity_id: @entity.id)
    assert_operator closing_entries_of_entity.count, :>, 0

    post change_year_end_reports_url(locale: :en, entity_id: @entity.id)
    assert_response :redirect
    assert_equal 0, closing_entries_of_entity.count,
                 "every closing entry of the entity must be removed"
    assert_nil FiscalPeriod.last_closed_on(@entity)
    # and the picker is back, so a new pattern can be chosen
    get new_year_end_reports_url(locale: :en, entity_id: @entity.id)
    assert_select "form.form_year_end input[type=radio][name=pattern][value=uk]"
  end

  # --- Closing: everything is a POST to create_year_end ---

  test "first close of a finished past year posts a closing entry" do
    post_income(Date.new(@year - 1, 6, 1))
    assert_difference -> { JournalEntry.where(closing_entry: true).count }, +1 do
      post create_year_end_reports_url(locale: :en, entity_id: @entity.id, pattern: "calendar")
    end
    assert_response :redirect
    assert_match "dashboard", @response.redirect_url
  end

  test "a subsequent close (no pattern) advances and posts the next year" do
    post_income(Date.new(@year - 2, 6, 1))
    post create_year_end_reports_url(locale: :en, entity_id: @entity.id, pattern: "calendar")
    post_income(Date.new(@year - 1, 6, 1))
    assert_difference -> { JournalEntry.where(closing_entry: true).count }, +1 do
      post create_year_end_reports_url(locale: :en, entity_id: @entity.id) # no pattern
    end
    assert_response :redirect
  end

  test "a custom (Other) year-end given as day + month closes" do
    post_income(Date.new(@year - 1, 3, 1))
    assert_difference -> { JournalEntry.where(closing_entry: true).count }, +1 do
      post create_year_end_reports_url(locale: :en, entity_id: @entity.id,
                                           pattern: "other", year_end_day: 30, year_end_month: 6)
    end
    assert_response :redirect
  end

  test "an impossible custom year-end (31 February) bounces back to the picker" do
    post_income(Date.new(@year - 2, 1, 1))
    assert_no_difference -> { JournalEntry.where(closing_entry: true).count } do
      post create_year_end_reports_url(locale: :en, entity_id: @entity.id,
                                           pattern: "other", year_end_day: 31, year_end_month: 2)
    end
    assert_response :redirect
    assert_match "new_year_end", @response.redirect_url
  end

  test "cannot close an unfinished year" do
    post_income(Date.current)
    assert_no_difference -> { JournalEntry.where(closing_entry: true).count } do
      post create_year_end_reports_url(locale: :en, entity_id: @entity.id, pattern: "calendar")
    end
    assert_response :redirect
  end
end
