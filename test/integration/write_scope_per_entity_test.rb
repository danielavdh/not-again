require "test_helper"

# Access levels are granted PER ENTITY, and enforcing them per admin breaks
# that: a write gate asking read_only? — true only when EVERY link is read_only
# — while the data scopes span every linked entity means one full_access link
# anywhere unlocks writing everywhere, so sudo granting an admin full access to
# a new business silently promotes them on all their others.
#
# admins(:mixed) is that admin: full_access on family_biz(10), read_only on
# personal(01). Reading 01 is fine. Changing anything in 01 is not.
class WriteScopePerEntityTest < ActiveSupport::TestCase
  setup do
    @mixed       = admins(:mixed)
    @full_access = admins(:one)   # full_access on personal(01) + spouse(03)
    @read_only   = admins(:read_only)
    @upload_only = admins(:upload_only)
    @sudo        = admins(:sudo)
  end

  test "the read scope still spans every linked entity" do
    assert_equal %w[01 10], @mixed.entity_codes.sort
  end

  test "the write scope covers only the full_access link" do
    assert_equal ["10"], @mixed.writable_entity_codes
  end

  test "writable_accounts excludes the read-only entity" do
    assert @mixed.accessible_accounts.exists?(accounts(:boss_bank).id),
      "01 accounts stay readable"
    assert_not @mixed.writable_accounts.exists?(accounts(:boss_bank).id),
      "01 accounts are not writable"
    assert @mixed.writable_accounts.exists?(accounts(:bank_gbp).id),
      "10 accounts are writable"
  end

  test "writable_receipts follows receipt access, which read_only never grants" do
    assert @mixed.accessible_receipts.exists?(receipts(:personal_receipt).id)
    assert_not @mixed.writable_receipts.exists?(receipts(:personal_receipt).id)
  end

  test "a read-only admin can write nowhere" do
    assert_empty @read_only.writable_entity_codes
    assert_equal 0, @read_only.writable_accounts.count
  end

  test "an upload-receipts admin can write no books, but owns their receipts entity" do
    assert_empty @upload_only.writable_entity_codes
    assert_equal 0, @upload_only.writable_accounts.count
    assert_equal [entities(:personal).id], @upload_only.upload_entity_ids
  end

  test "a uniformly full-access admin writes everywhere they read" do
    assert_equal @full_access.entity_codes.sort, @full_access.writable_entity_codes.sort
  end

  test "sudo without entity links writes everywhere" do
    assert_equal Account.count, @sudo.writable_accounts.count
    assert_equal Entity.pluck(:id).sort, @sudo.writable_entity_ids.sort
  end

  # AdminEntity#owner_holds_no_entity refuses this outright, so save(validate:
  # false) simulates a pre-existing row from before that guard, proving the
  # accessor is defence in depth rather than the only protection.
  test "sudo is not blocked by an access level on a link they do hold" do
    AdminEntity.new(admin: @sudo, entity: entities(:personal), access_level: :read_only).save!(validate: false)
    assert_includes @sudo.writable_entity_codes, "01"
  end
end

# The same rule, exercised through the controllers — the model scope is only
# worth anything if the write paths actually resolve through it.
class WriteScopeRequestTest < ActionDispatch::IntegrationTest
  setup do
    @mixed        = admins(:mixed)
    @own_account  = accounts(:bank_gbp)   # 110001 → entity 10, writable
    @read_account = accounts(:boss_bank)  # 101001 → entity 01, read-only
    @read_expense = accounts(:boss_drawings)
    sign_in_as(@mixed)
  end

  def assert_refused
    assert_redirected_to dashboard_path(locale: :en)
    assert_equal I18n.t("access.read_only_deny"), flash[:alert]
  end

  # --- reading the read-only entity is untouched ---

  test "the read-only entity's accounts are still visible" do
    get account_url(@read_account, locale: :en)
    assert_response :success
  end

  test "the read-only entity's ledger is still visible" do
    get ledger_account_url(@read_account, locale: :en)
    assert_response :success
  end

  # --- accounts ---

  test "cannot open the edit form for an account in the read-only entity" do
    get edit_account_url(@read_account, locale: :en)
    assert_refused
  end

  test "cannot update an account in the read-only entity" do
    original = @read_account.name
    patch account_url(@read_account, locale: :en), params: {
      account: { name: "Renamed by someone else" }
    }
    assert_refused
    assert_equal original, @read_account.reload.name
  end

  test "cannot destroy an account in the read-only entity" do
    assert_no_difference("Account.count") do
      delete account_url(@read_account, locale: :en)
    end
    assert_refused
  end

  test "cannot quick-map tax on an account in the read-only entity" do
    patch quick_map_tax_account_url(@read_account, locale: :en), params: { tax_category_key: "x" }
    assert_refused
  end

  test "can still update an account in their own entity" do
    patch account_url(@own_account, locale: :en), params: {
      account: { name: "Renamed by the bookkeeper" }
    }
    assert_redirected_to accounts_url(locale: :en)
    assert_equal "Renamed by the bookkeeper", @own_account.reload.name
  end

  test "cannot create an account inside the read-only entity" do
    assert_no_difference("Account.count") do
      post accounts_url(locale: :en), params: {
        account: { code: "501009", name: "Sneaked in", account_type: :expense, currency: "GBP", active: true }
      }
    end
    assert_response :unprocessable_entity
  end

  test "can create an account inside their own entity" do
    assert_difference("Account.count") do
      post accounts_url(locale: :en), params: {
        account: { code: "510009", name: "New expense", account_type: :expense, currency: "GBP", active: true }
      }
    end
    assert_redirected_to accounts_url(locale: :en)
  end

  # --- bank entries ---

  test "cannot open a deposit form on a bank account in the read-only entity" do
    get new_deposit_account_url(@read_account, locale: :en)
    assert_refused
  end

  test "cannot post a deposit into the read-only entity" do
    assert_no_difference("JournalEntry.count") do
      post create_deposit_account_url(@read_account, locale: :en), params: {
        journal_entry: {
          entry_date: Date.current.to_s,
          memo: "Injected",
          postings_attributes: {
            "0" => { account_id: @read_expense.id, amount: "10.00", currency: "GBP", entry_type: "credit" }
          }
        }
      }
    end
    assert_refused
  end

  test "cannot aim a posting at the read-only entity from their own bank account" do
    assert_no_difference("JournalEntry.count") do
      post create_deposit_account_url(@own_account, locale: :en), params: {
        journal_entry: {
          entry_date: Date.current.to_s,
          memo: "Reaching across",
          postings_attributes: {
            "0" => { account_id: @read_expense.id, amount: "10.00", currency: "GBP", entry_type: "credit" }
          }
        }
      }
    end
    assert_refused
  end

  # --- journal entries ---

  test "cannot create a journal entry inside the read-only entity" do
    assert_no_difference("JournalEntry.count") do
      post journal_entries_url(locale: :en), params: {
        journal_entry: {
          entry_date: Date.current.to_s,
          memo: "Injected",
          postings_attributes: {
            "0" => { account_id: @read_account.id, amount: "10.00", currency: "GBP", entry_type: "debit" },
            "1" => { account_id: @read_expense.id, amount: "10.00", currency: "GBP", entry_type: "credit" }
          }
        }
      }
    end
    assert_refused
  end

  test "can create a journal entry inside their own entity" do
    assert_difference("JournalEntry.count") do
      post journal_entries_url(locale: :en), params: {
        journal_entry: {
          entry_date: Date.current.to_s,
          memo: "Mine",
          postings_attributes: {
            "0" => { account_id: @own_account.id, amount: "10.00",
                     currency: "GBP", entry_type: "debit" },
            "1" => { account_id: accounts(:income_sales).id, amount: "10.00",
                     currency: "GBP", entry_type: "credit" }
          }
        }
      }
    end
  end

  test "cannot change an existing entry in the read-only entity" do
    entry = JournalEntry.create!(
      entry_date: Date.current,
      memo: "Theirs",
      postings_attributes: [
        { account_id: @read_account.id, amount: 25, currency: "GBP", entry_type: :debit },
        { account_id: @read_expense.id, amount: 25, currency: "GBP", entry_type: :credit }
      ]
    )

    get journal_entry_url(entry, locale: :en)
    assert_response :success, "reading somebody else's entry is still allowed"

    get edit_journal_entry_url(entry, locale: :en)
    assert_refused

    patch journal_entry_url(entry, locale: :en),
      params: { journal_entry: { memo: "Mine now" } }
    assert_refused
    assert_equal "Theirs", entry.reload.memo

    was_posted = entry.reload.posted?
    patch unpost_journal_entry_url(entry, locale: :en)
    assert_refused
    assert_equal was_posted, entry.reload.posted?, "posted state must be untouched"

    assert_no_difference("JournalEntry.count") do
      delete journal_entry_url(entry, locale: :en)
    end
    assert_refused
  end

  # --- receipts ---

  test "cannot destroy a receipt belonging to the read-only entity" do
    assert_no_difference("Receipt.count") do
      delete receipt_url(receipts(:personal_receipt), locale: :en)
    end
    assert_refused
  end

  test "cannot edit a receipt belonging to the read-only entity" do
    get edit_receipt_url(receipts(:personal_receipt), locale: :en)
    assert_refused
  end

  # --- year end ---

  test "cannot close the year on the read-only entity" do
    assert_no_difference("JournalEntry.count") do
      post create_year_end_reports_url(locale: :en),
        params: { entity_id: entities(:personal).id, pattern: "calendar" }
    end
    assert_refused
  end

  test "cannot reopen closes on the read-only entity" do
    post change_year_end_reports_url(locale: :en),
      params: { entity_id: entities(:personal).id }
    assert_refused
  end

  # --- report groups ---

  test "cannot change a report group belonging to the read-only entity" do
    group = ReportGroup.create!(name: "Theirs", entity: entities(:personal))
    patch report_group_url(group, locale: :en), params: {
      report_group: { name: "Mine now" }
    }
    assert_refused
    assert_equal "Theirs", group.reload.name
  end

  test "can change a report group belonging to their own entity" do
    group = ReportGroup.create!(name: "Ours", entity: entities(:family_biz))
    patch report_group_url(group, locale: :en), params: {
      report_group: { name: "Renamed" }
    }
    assert_equal "Renamed", group.reload.name
  end
end
