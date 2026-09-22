# frozen_string_literal: true
require "test_helper"

class JournalEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @journal_entry = journal_entries(:posted_deposit)
    @draft_entry = journal_entries(:draft_entry)
    @bank = accounts(:bank_gbp)
    @income = accounts(:income_sales)
    @expense = accounts(:expenses_general)
    @admin = admins(:two)
    sign_in_as(@admin)
  end

  # refresh_affected_closing_entry regenerates entity 10's archive too, and
  # several tests below land inside its closed period on purpose and trigger
  # exactly that.
  teardown do
    FileUtils.rm_rf(uploads_path("archives", "10"))
  end

  # ==================== Index Tests ====================

  test "should get index" do
    get journal_entries_url(locale: :en)
    assert_response :success
  end

  test "index shows all journal entries" do
    get journal_entries_url(locale: :en)
    assert_response :success
  end

  # ==================== Show Tests ====================

  test "should show journal entry" do
    get journal_entry_url(locale: :en, id: @journal_entry)
    assert_response :success
  end

  test "show displays postings" do
    get journal_entry_url(locale: :en, id: @journal_entry)
    assert_response :success
  end

  test "an app-generated close offers no copy, edit, unpost or delete on its own page" do
    @admin.update!(show_journal_entries: true) # full_access_pro?, or copy/edit/delete never render anyway
    closing = journal_entries(:closing_entry_fy2024)
    get journal_entry_url(locale: :en, id: closing)
    assert_response :success
    assert_select "div.crud_navigation a[href=?]", duplicate_journal_entry_path(closing, locale: :en), count: 0
    assert_select "div.crud_navigation a[href=?]", edit_journal_entry_path(closing, locale: :en), count: 0
    assert_select "div.crud_navigation form[action^=?]", unpost_journal_entry_path(closing, locale: :en), count: 0
    assert_select "div.crud_navigation form input[name=_method][value=delete]", count: 0

    # an ordinary posted entry still offers its normal actions
    get journal_entry_url(locale: :en, id: @journal_entry)
    assert_select "div.crud_navigation a[href=?]", duplicate_journal_entry_path(@journal_entry, locale: :en)
    assert_select "div.crud_navigation a[href=?]", edit_journal_entry_path(@journal_entry, locale: :en)
    assert_select "div.crud_navigation form[action^=?]", unpost_journal_entry_path(@journal_entry, locale: :en)
    get journal_entry_url(locale: :en, id: @draft_entry) # delete is offered on drafts only
    assert_select "div.crud_navigation form input[name=_method][value=delete]"
  end

  test "copying a closing entry produces an ordinary entry, not a second close" do
    closing = journal_entries(:closing_entry_fy2024)
    get duplicate_journal_entry_url(locale: :en, id: closing)
    assert_response :success
    # The copy form offers an unticked closing-entry box and no period fields —
    # i.e. the flag and dates did not travel with the duplicate.
    assert_select "input#journal_entry_closing_entry"
    assert_select "input#journal_entry_closing_entry[checked]", count: 0
    assert_select "input#journal_entry_period_start", count: 0
    assert_select "input#journal_entry_period_end",   count: 0
  end

  test "show announces the period on a closing entry, and says nothing on an ordinary one" do
    closing = journal_entries(:closing_entry_fy2024)
    get journal_entry_url(locale: :en, id: closing)
    assert_response :success
    assert_select "div.je-show", text: /#{Regexp.escape(I18n.t("attrs.closing_entry"))}/
    assert_match I18n.l(closing.period_start, format: :short_date), response.body
    assert_match I18n.l(closing.period_end,   format: :short_date), response.body

    get journal_entry_url(locale: :en, id: @journal_entry)
    assert_select "div.je-show", text: /#{Regexp.escape(I18n.t("attrs.closing_entry"))}/, count: 0
  end

  # ==================== New/Create Tests ====================

  test "should get new" do
    get new_journal_entry_url(locale: :en)
    assert_response :success
  end

  test "should create balanced journal entry" do
    assert_difference("JournalEntry.count") do
      post journal_entries_url(locale: :en), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Test entry",
          postings_attributes: {
            "0" => { account_id: @bank.id, amount: 10000, currency: "GBP", entry_type: "debit" },
            "1" => { account_id: @income.id, amount: 10000, currency: "GBP", entry_type: "credit" }
          }
        }
      }
    end
    assert_redirected_to journal_entry_url(locale: :en, id: JournalEntry.last)
  end

  test "create fails for unbalanced entry" do
    assert_no_difference("JournalEntry.count") do
      post journal_entries_url(locale: :en), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Unbalanced entry",
          postings_attributes: {
            "0" => { account_id: @bank.id, amount: 10000, currency: "GBP", entry_type: "debit" },
            "1" => { account_id: @income.id, amount: 5000, currency: "GBP", entry_type: "credit" }
          }
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create fails with all blank postings and re-renders two rows" do
    assert_no_difference("JournalEntry.count") do
      post journal_entries_url(locale: :en), params: {
        journal_entry: {
          entry_date: Date.current,
          postings_attributes: {
            "0" => { account_id: "", amount: "", amount_display: "", entry_type: "debit" },
            "1" => { account_id: "", amount: "", amount_display: "", entry_type: "credit" }
          }
        }
      }
    end
    assert_response :unprocessable_entity
    assert_equal 2, controller.instance_variable_get(:@journal_entry).postings.size
  end

  test "create fails without balance sheet account" do
    assert_no_difference("JournalEntry.count") do
      post journal_entries_url(locale: :en), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "No balance sheet account",
          postings_attributes: {
            "0" => { account_id: @income.id, amount: 10000, currency: "GBP", entry_type: "debit" },
            "1" => { account_id: @expense.id, amount: 10000, currency: "GBP", entry_type: "credit" }
          }
        }
      }
    end
    assert_response :unprocessable_entity
  end

  # ==================== Edit/Update Tests ====================

  test "should get edit" do
    get edit_journal_entry_url(locale: :en, id: @draft_entry)
    assert_response :success
  end

  test "should update journal entry" do
    patch journal_entry_url(locale: :en, id: @draft_entry), params: {
      journal_entry: {
        memo: "Updated memo"
      }
    }
    assert_redirected_to journal_entry_url(locale: :en, id: @draft_entry)
    @draft_entry.reload
    assert_equal "Updated memo", @draft_entry.memo
  end

  # ==================== Destroy Tests ====================

  test "should destroy unposted entry" do
    assert_difference("JournalEntry.count", -1) do
      delete journal_entry_url(locale: :en, id: @draft_entry)
    end
    assert_redirected_to journal_entries_url(locale: :en)
  end

  test "destroy redirects to ledger when from=ledger" do
    assert_difference("JournalEntry.count", -1) do
      delete journal_entry_url(locale: :en, id: @draft_entry, from: 'ledger', account_id: @bank.id)
    end
    assert_redirected_to ledger_account_url(locale: :en, id: @bank.id)
  end

  test "cannot destroy posted entry" do
    assert_no_difference("JournalEntry.count") do
      delete journal_entry_url(locale: :en, id: @journal_entry)
    end
  end

  test "emptying a JE (all postings marked for deletion) deletes it instead of erroring" do
    p1, p2 = @draft_entry.postings.to_a
    assert_difference("JournalEntry.count", -1) do
      patch journal_entry_url(locale: :en, id: @draft_entry), params: {
        journal_entry: { postings_attributes: {
          "0" => { id: p1.id, _destroy: "1" },
          "1" => { id: p2.id, _destroy: "1" }
        } }
      }
    end
    assert_not JournalEntry.exists?(@draft_entry.id)
    assert_redirected_to journal_entries_url(locale: :en)
  end

  test "marking only SOME postings for deletion does not trigger the empty-delete" do
    p1, = @draft_entry.postings.to_a
    assert_no_difference("JournalEntry.count") do
      patch journal_entry_url(locale: :en, id: @draft_entry), params: {
        journal_entry: { postings_attributes: { "0" => { id: p1.id, _destroy: "1" } } }
      }
    end
    assert JournalEntry.exists?(@draft_entry.id), "entry survives (a survivor remains → normal save path)"
  end

  # ==================== Post/Unpost Tests ====================

  test "post action posts entry" do
    patch post_journal_entry_url(locale: :en, id: @draft_entry)
    @draft_entry.reload
    assert @draft_entry.posted?
  end

  test "post action fails for unbalanced entry" do
    entry = JournalEntry.new(entry_date: Date.current, memo: "Unbalanced", posted: false)
    entry.save(validate: false)
    entry.postings.create!(account: @bank, amount: 10000, currency: "GBP", entry_type: :debit)

    patch post_journal_entry_url(locale: :en, id: entry)
    entry.reload
    assert_not entry.posted?
  end

  test "unpost action unposts entry" do
    patch unpost_journal_entry_url(locale: :en, id: @journal_entry)
    @journal_entry.reload
    assert_not @journal_entry.posted?
  end

  test "unpost shows plain notice when entry is in open period" do
    patch unpost_journal_entry_url(locale: :en, id: @journal_entry)
    assert_redirected_to journal_entry_url(locale: :en, id: @journal_entry)
    assert_match I18n.t("journal_entries.unposted"), flash[:notice]
    assert_no_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
  end

  test "post shows plain notice when entry is in open period" do
    patch post_journal_entry_url(locale: :en, id: @draft_entry)
    assert_match I18n.t("journal_entries.posted"), flash[:notice]
    assert_no_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
  end

  # ==================== Closed Period / refresh_affected_closing_entry Tests
  # ====================

  test "posting entry in closed period updates closing entry and appends suffix to notice" do
    closing = journal_entries(:closing_entry_fy2024)
    old_id  = closing.id

    # build a draft entry dated inside the closed period
    entry = JournalEntry.new(entry_date: Date.new(2023, 11, 1), memo: "Late entry", posted: false)
    entry.save!(validate: false)
    entry.postings.create!(account: accounts(:bank_gbp),    amount: 5000, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: accounts(:income_sales), amount: 5000, currency: "GBP", entry_type: :credit)

    patch post_journal_entry_url(locale: :en, id: entry)

    assert_match I18n.t("journal_entries.posted"), flash[:notice]
    assert_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
    assert_not JournalEntry.exists?(old_id), "old closing entry should be destroyed"
    new_closing = JournalEntry.where(closing_entry: true, period_start: Date.new(2023, 4, 1), period_end: Date.new(2024, 3, 31)).first
    assert new_closing, "a new closing entry should be created"
    assert new_closing.posted?, "new closing entry should be posted"
  end

  test "unposting entry in closed period updates closing entry and uses unposted notice" do
    closing = journal_entries(:closing_entry_fy2024)
    old_id  = closing.id

    # a posted entry inside the closed period
    entry = JournalEntry.new(entry_date: Date.new(2023, 11, 1), memo: "Late entry", posted: true)
    entry.save!(validate: false)
    entry.postings.create!(account: accounts(:bank_gbp),    amount: 5000, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: accounts(:income_sales), amount: 5000, currency: "GBP", entry_type: :credit)

    patch unpost_journal_entry_url(locale: :en, id: entry)

    assert_match I18n.t("journal_entries.unposted"), flash[:notice]
    assert_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
    assert_no_match I18n.t("journal_entries.posted"), flash[:notice]
    assert_not JournalEntry.exists?(old_id), "old closing entry should be destroyed"
  end

  # A pro may close a year by hand instead of using the assisted flow. Such an
  # entry posts to an equity account of their own, not to a locked retained-
  # earnings account in the reserved 3EE9xx range, so the automated refresh must
  # leave it strictly alone rather than destroying and regenerating it.
  test "a hand-built closing entry is never destroyed or rebuilt by the automated refresh" do
    manual = JournalEntry.new(
      entry_date:   Date.new(2022, 3, 31),
      memo:         "Manual year end close",
      posted:       true,
      closing_entry: true,
      period_start: Date.new(2021, 4, 1),
      period_end:   Date.new(2022, 3, 31)
    )
    manual.save!(validate: false)
    manual.postings.create!(account: accounts(:income_sales),   amount: 5000, currency: "GBP", entry_type: :debit)
    manual.postings.create!(account: accounts(:equity_capital), amount: 5000, currency: "GBP", entry_type: :credit)

    entry = JournalEntry.new(entry_date: Date.new(2021, 11, 1), memo: "Late entry", posted: false)
    entry.save!(validate: false)
    entry.postings.create!(account: accounts(:bank_gbp),     amount: 5000, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: accounts(:income_sales), amount: 5000, currency: "GBP", entry_type: :credit)

    patch post_journal_entry_url(locale: :en, id: entry)

    assert JournalEntry.exists?(manual.id), "a hand-built closing entry must survive untouched"
    assert_equal 2, manual.reload.postings.count, "its postings must not be regenerated"
    assert_no_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
  end

  test "unposting a closing entry itself does not trigger cascade" do
    closing = journal_entries(:closing_entry_fy2024)
    count_before = JournalEntry.where(closing_entry: true).count

    patch unpost_journal_entry_url(locale: :en, id: closing)

    closing.reload
    assert_not closing.posted?, "closing entry should be unposted"
    assert_equal count_before, JournalEntry.where(closing_entry: true).count, "no other closing entries should be created or destroyed"
    assert_no_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
  end

  test "posting a closing entry itself does not trigger cascade" do
    closing = journal_entries(:closing_entry_fy2024)
    closing.update_column(:posted, false)
    count_before = JournalEntry.where(closing_entry: true).count

    patch post_journal_entry_url(locale: :en, id: closing)

    closing.reload
    assert closing.posted?, "closing entry should be posted"
    assert_equal count_before, JournalEntry.where(closing_entry: true).count
    assert_no_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
  end

  test "entry on period boundary start date triggers closing entry update" do
    closing = journal_entries(:closing_entry_fy2024)
    old_id  = closing.id

    entry = JournalEntry.new(entry_date: Date.new(2023, 4, 1), memo: "First day of period", posted: false)
    entry.save!(validate: false)
    entry.postings.create!(account: accounts(:bank_gbp),    amount: 1000, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: accounts(:income_sales), amount: 1000, currency: "GBP", entry_type: :credit)

    patch post_journal_entry_url(locale: :en, id: entry)

    assert_not JournalEntry.exists?(old_id), "closing entry should be replaced on period_start date"
  end

  test "entry on period boundary end date triggers closing entry update" do
    closing = journal_entries(:closing_entry_fy2024)
    old_id  = closing.id

    entry = JournalEntry.new(entry_date: Date.new(2024, 3, 31), memo: "Last day of period", posted: false)
    entry.save!(validate: false)
    entry.postings.create!(account: accounts(:bank_gbp),    amount: 1000, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: accounts(:income_sales), amount: 1000, currency: "GBP", entry_type: :credit)

    patch post_journal_entry_url(locale: :en, id: entry)

    assert_not JournalEntry.exists?(old_id), "closing entry should be replaced on period_end date"
  end

  test "entry one day before closed period does not trigger closing entry update" do
    closing = journal_entries(:closing_entry_fy2024)
    old_id  = closing.id

    entry = JournalEntry.new(entry_date: Date.new(2023, 3, 31), memo: "Day before period", posted: false)
    entry.save!(validate: false)
    entry.postings.create!(account: accounts(:bank_gbp),    amount: 1000, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: accounts(:income_sales), amount: 1000, currency: "GBP", entry_type: :credit)

    patch post_journal_entry_url(locale: :en, id: entry)

    assert JournalEntry.exists?(old_id), "closing entry should not be touched"
    assert_no_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
  end

  test "entry one day after closed period does not trigger closing entry update" do
    closing = journal_entries(:closing_entry_fy2024)
    old_id  = closing.id

    entry = JournalEntry.new(entry_date: Date.new(2024, 4, 1), memo: "Day after period", posted: false)
    entry.save!(validate: false)
    entry.postings.create!(account: accounts(:bank_gbp),    amount: 1000, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: accounts(:income_sales), amount: 1000, currency: "GBP", entry_type: :credit)

    patch post_journal_entry_url(locale: :en, id: entry)

    assert JournalEntry.exists?(old_id), "closing entry should not be touched"
    assert_no_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
  end

  # Entity 04 has never closed anything of its own, but once it shares a family
  # with entity 10, an edit to ITS books dated inside a calendar year the family
  # already has an ARCHIVE for must still make that archive stale and regenerate
  # it — even though 04 has no closing entry of its own and never touches 10's.
  test "an edit entirely within a sibling's own books regenerates the family archive but never touches another entity's closing entry" do
    group = EntityGroup.create!(name: "Household Test")
    travel_to(Date.new(2020, 1, 1)) do
      entities(:family_biz).update!(entity_group: group)
      entities(:daughter).update!(entity_group: group)
    end

    closing   = journal_entries(:closing_entry_fy2024)
    old_id    = closing.id
    scope_key = Archives::Storage.scope_key_for(entities(:family_biz).reload)

    # The family already has a 2024 archive (from some earlier close).
    key = Archives::Storage.key_for(scope_key, 2024, year_end: true)
    Archives::Storage.upload(key, "placeholder — pre-correction content")

    # Entirely entity 04's own accounts. Entity 04 has never closed anything.
    entry = JournalEntry.new(entry_date: Date.new(2024, 7, 1), memo: "Daughter's late entry", posted: false)
    entry.save!(validate: false)
    entry.postings.create!(account: accounts(:daughter_bank),   amount: 500, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: accounts(:daughter_income), amount: 500, currency: "GBP", entry_type: :credit)

    patch post_journal_entry_url(locale: :en, id: entry)

    # No suffix: entity 04 itself has no closing entry to rebuild, and this
    # is a silent, background archive refresh, not a user-facing correction.
    assert_no_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
    assert JournalEntry.exists?(old_id), "entity 10's own closing entry must not be touched by a sibling's edit"

    refreshed = Archives::Storage.read(key)
    assert_includes refreshed, "Daughter's late entry",
      "the family's 2024 archive should have been regenerated to include the correction"
    assert_not_includes refreshed, "placeholder", "the stale content must actually be replaced, not left alone"
  ensure
    if group
      FileUtils.rm_rf(uploads_path("archives", "g#{group.id}"))
    end
  end

  # A UK-pattern member's own fiscal close has nothing to do with WHICH
  # calendar-year family archive a correction touches: that is decided by the
  # corrected entry's own date, not by the closing entity's fiscal year.
  test "a correction inside a UK member's fiscal year touches only the calendar-year archive its own date falls into" do
    group  = EntityGroup.create!(name: "Staggered Correction Test")
    entity = Entity.create!(name: "UK Member", code: "97", active: true, entity_group: group)
    backdate_family_membership!(entity)
    income = Account.create!(code: "497001", name: "Sales", account_type: :income, active: true)
    bank   = Account.create!(code: "197001", name: "Bank",  account_type: :asset, currency: "GBP", active: true)
    re     = Account.create!(code: "397001", name: "Retained Earnings", account_type: :equity,
                              currency: "GBP", locked: true, active: true)

    closing = JournalEntry.new(entry_date: Date.new(2026, 4, 5), memo: "Year end close", posted: true,
                                closing_entry: true, period_start: Date.new(2025, 4, 6), period_end: Date.new(2026, 4, 5))
    closing.save!(validate: false)
    closing.postings.create!(account: re, entry_type: :credit, amount: 1000, currency: "GBP")
    old_id = closing.id

    scope_key = Archives::Storage.scope_key_for(entity)
    key_2025  = Archives::Storage.key_for(scope_key, Date.new(2025, 12, 31), year_end: true)
    key_2026  = Archives::Storage.key_for(scope_key, Date.new(2026, 12, 31), year_end: true)
    Archives::Storage.upload(key_2025, "placeholder 2025")
    Archives::Storage.upload(key_2026, "placeholder 2026")

    # No entity link needed: sudo writes everywhere regardless, and
    # AdminEntity#owner_holds_no_entity refuses one anyway.
    sign_in_as(admins(:sudo))

    # October 2025 — inside this entity's OWN fiscal year (2025-04-06 to
    # 2026-04-05), so its own closing entry needs rebuilding, but inside the
    # FAMILY'S 2025 calendar-year archive, not 2026.
    entry = JournalEntry.new(entry_date: Date.new(2025, 10, 1), memo: "Late October entry", posted: false)
    entry.save!(validate: false)
    entry.postings.create!(account: bank,   amount: 300, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: income, amount: 300, currency: "GBP", entry_type: :credit)

    patch post_journal_entry_url(locale: :en, id: entry)

    assert_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
    assert_not JournalEntry.exists?(old_id), "the entity's own fiscal-year close (ending 2026-04-05) must be rebuilt"

    assert_includes Archives::Storage.read(key_2025), "Late October entry"
    assert_not_includes Archives::Storage.read(key_2025), "placeholder"
    refreshed_2026 = Archives::Storage.read(key_2026)
    assert_equal "placeholder 2026", refreshed_2026, "the 2026 archive must be untouched — the correction's own date is in 2025"
  ensure
    FileUtils.rm_rf(uploads_path("archives", "g#{group.id}")) if group
  end

  test "entry for different entity does not touch another entity closing entry" do
    closing = journal_entries(:closing_entry_fy2024)
    old_id  = closing.id

    # daughter_bank is entity 04, closing entry is entity 10
    entry = JournalEntry.new(entry_date: Date.new(2023, 11, 1), memo: "Wrong entity entry", posted: false)
    entry.save!(validate: false)
    entry.postings.create!(account: accounts(:daughter_bank), amount: 1000, currency: "GBP", entry_type: :debit)
    entry.postings.create!(account: accounts(:daughter_bank), amount: 1000, currency: "GBP", entry_type: :credit)

    patch post_journal_entry_url(locale: :en, id: entry)

    assert JournalEntry.exists?(old_id), "entity 10 closing entry should not be touched by entity 04 entry"
    assert_no_match I18n.t("journal_entries.closing_entry_updated_suffix"), flash[:notice]
  end

  test "closing entry with closing_entry false does not trigger refresh even if dates overlap" do
    closing = journal_entries(:closing_entry_fy2024)
    old_id  = closing.id

    # A manual JE (closing_entry: false) dated inside the period — should NOT
    # trigger refresh
    manual = JournalEntry.new(entry_date: Date.new(2023, 11, 1), memo: "Manual close", posted: false, closing_entry: false)
    manual.save!(validate: false)
    manual.postings.create!(account: accounts(:bank_gbp),     amount: 1000, currency: "GBP", entry_type: :debit)
    manual.postings.create!(account: accounts(:income_sales),  amount: 1000, currency: "GBP", entry_type: :credit)

    # The manual entry is a normal entry being posted, so closing_entry? is
    # false on the entry being acted on and refresh WILL fire and look for
    # closing entries. This checks that entity 10's service-created closing
    # entry IS found and updated, because detection looks at the closing_entry
    # flag on the AFFECTED entry, not the one being posted.
    patch post_journal_entry_url(locale: :en, id: manual)

    # The service-generated closing_entry_fy2024 should have been replaced
    assert_not JournalEntry.exists?(old_id), "service closing entry should be updated when normal entry posted in period"
  end

  # ==================== Duplicate Tests ====================

  test "duplicate shows form with copied data" do
    get duplicate_journal_entry_url(locale: :en, id: @journal_entry)
    assert_response :success
  end

  # A pro sees the plain copy notice — the ledger already told them this row is
  # a journal entry. The only organic path a non-pro has to this action is the
  # ledger of one of the entry's own balance accounts, since show.html.erb's
  # Copy and Edit are full_access_pro?-gated and the index is hidden from their
  # menu, so a non-pro reaching it needs the balancing warning instead.
  test "duplicate shows only the plain copy notice for a pro" do
    @admin.update!(show_journal_entries: true)
    get duplicate_journal_entry_url(locale: :en, id: @journal_entry)
    assert_equal I18n.t("crud.is_copy"), flash[:notice]
  end

  test "duplicate shows the beginner balancing warning for a non-pro" do
    @admin.update!(show_journal_entries: false)
    get duplicate_journal_entry_url(locale: :en, id: @journal_entry)
    assert_equal I18n.t("journal_entries.duplicate.beginner_warning"), flash[:notice]
  end

  # sudo counts as pro unconditionally (Admin#full_access_pro?), regardless
  # of whether sudo happens to have show_journal_entries set.
  test "duplicate shows only the plain copy notice for sudo regardless of show_journal_entries" do
    sudo = admins(:sudo)
    sudo.update!(show_journal_entries: false)
    sign_in_as(sudo)
    get duplicate_journal_entry_url(locale: :en, id: @journal_entry)
    assert_equal I18n.t("crud.is_copy"), flash[:notice]
  end

  test "edit shows no extra notice for a pro" do
    @admin.update!(show_journal_entries: true)
    get edit_journal_entry_url(locale: :en, id: @journal_entry)
    assert_nil flash[:notice]
  end

  test "edit shows the beginner balancing warning for a non-pro" do
    @admin.update!(show_journal_entries: false)
    get edit_journal_entry_url(locale: :en, id: @journal_entry)
    assert_equal I18n.t("journal_entries.edit.beginner_warning"), flash[:notice]
  end
end
