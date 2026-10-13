# frozen_string_literal: true

require "test_helper"

# Digits 2 and 3 of an account's code ARE its entity. Changing them moves the
# account between businesses, so the question "may I write to this account?"
# has to be asked about where it is GOING, not only where it is now.
class AccountEntityMoveTest < ActionDispatch::IntegrationTest
  setup do
    # admins(:two) runs family_biz (10) and daughter (04). Nobody has given
    # them anything in personal (01).
    @admin = admins(:two)
    sign_in_as(@admin)
    @mine = Account.create!(code: "510500", name: "Movable", account_type: :expense)
  end

  test "an admin cannot move their own account into a business they do not run" do
    patch account_path(@mine), params: { account: { code: "501500", name: "Movable" } }

    assert_equal "510500", @mine.reload.code,
                 "01 is not theirs — the account must stay in 10"
  end

  # Once it has postings the ordinary rule covers it: the first three digits
  # are frozen, so the entity digits cannot move at all.
  test "an account with postings cannot be moved anywhere" do
    JournalEntry.create!(entry_date: Date.current, postings_attributes: [
      { account_id: @mine.id, amount: 5_000, entry_type: :debit },
      { account_id: accounts(:bank_gbp).id, amount: 5_000, entry_type: :credit }
    ])

    patch account_path(@mine), params: { account: { code: "501500", name: "Movable" } }
    assert_equal "510500", @mine.reload.code

    patch account_path(@mine), params: { account: { code: "504500", name: "Movable" } }
    assert_equal "510500", @mine.reload.code, "not even to a business they do run"
  end

  test "an admin cannot create an account in a business they do not run" do
    post accounts_path, params: { account: { code: "501600", name: "Sneaky",
                                             account_type: "expense" } }

    assert_nil Account.find_by(code: "501600")
  end

  test "an admin cannot even see an account of a business they do not run" do
    theirs = Account.create!(code: "501700", name: "Not yours", account_type: :expense)

    get account_path(theirs)
    assert_response :redirect, "reading is scoped, so this never resolves"
  end

  test "an admin can still renumber within a business they do run" do
    patch account_path(@mine), params: { account: { code: "510501", name: "Movable" } }

    assert_equal "510501", @mine.reload.code
  end

  test "and can move it between two businesses they both run" do
    patch account_path(@mine), params: { account: { code: "504500", name: "Movable" } }

    assert_equal "504500", @mine.reload.code, "04 is theirs too"
  end
end
