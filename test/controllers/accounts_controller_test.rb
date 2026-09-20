# frozen_string_literal: true
require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:bank_gbp)
    @bank_eur = accounts(:bank_eur)
    @daughter_bank = accounts(:daughter_bank)
    @income = accounts(:income_sales)
    @expense = accounts(:expenses_general)
    @expense_fees = accounts(:expenses_fees)
    @personal = accounts(:personal_drawings)
    @admin = admins(:two)
    sign_in_as(@admin)
  end

  # ==================== Index Tests ====================

  test "should get index" do
    get accounts_url(locale: :en)
    assert_response :success
  end

  # The bookkeeper's own reminder of what belongs in an account, shown on hover.
  # Never translated — it is what they wrote.
  test "a description is saved and hangs off the name as its title" do
    patch account_url(@expense, locale: :en), params: {
      account: { description: "Rent, rates, insurance, ground rent" }
    }
    assert_equal "Rent, rates, insurance, ground rent", @expense.reload.description

    get accounts_url(locale: :en)
    assert_select "span.account-name[title=?]", "Rent, rates, insurance, ground rent"
  end

  test "and an account without one carries no title at all" do
    get accounts_url(locale: :en)
    assert_select "span.account-name[title]", false,
                  "an empty title would be a tooltip that says nothing"
  end

  test "index filters by code" do
    get accounts_url(locale: :en), params: { q: { code_cont: "110" } }
    assert_response :success
  end

  test "index filters by name" do
    get accounts_url(locale: :en), params: { q: { name_cont: "Bank" } }
    assert_response :success
  end

  test "index returns json for ajax requests" do
    get accounts_url(locale: :en), headers: { "Accept" => "application/json" }
    assert_response :success
  end

  test "filter treats underscore as literal not SQL wildcard" do
    # '_10001' would match code '110001' if _ is not escaped (SQL LIKE wildcard
    # matches any char)
    get accounts_url(locale: :en),
        params: { filter: "_10001" },
        headers: { "Accept" => "application/json" }
    assert_response :success
    body = response.parsed_body
    refute_includes body["html"], "Bank GBP"
  end

  test "filter treats percent as literal not SQL wildcard" do
    get accounts_url(locale: :en),
        params: { filter: "%" },
        headers: { "Accept" => "application/json" }
    assert_response :success
    body = response.parsed_body
    refute_includes body["html"], "Bank GBP"
  end

  test "index exports csv" do
    get accounts_url(locale: :en, format: :csv)
    assert_response :success
    assert_equal "text/csv", response.content_type.split(";").first
  end

  # ==================== CRUD Tests ====================

  test "should show account" do
    get account_url(locale: :en, id: @account)
    assert_response :success
  end

  test "show displays balance" do
    get account_url(locale: :en, id: @account)
    assert_response :success
  end

  test "should get new" do
    get new_account_url(locale: :en)
    assert_response :success
  end

  test "should create account" do
    assert_difference("Account.count") do
      post accounts_url(locale: :en), params: {
        account: { code: "110999", name: "Test Bank", account_type: :asset, currency: "GBP", active: true }
      }
    end
    assert_redirected_to accounts_url(locale: :en)
  end

  test "create fails with invalid data" do
    assert_no_difference("Account.count") do
      post accounts_url(locale: :en), params: {
        account: { code: "", name: "", account_type: nil }
      }
    end
    assert_response :unprocessable_entity
  end

  # --- #6 add-account-on-the-fly (cross-entity) -------------------------------

  test "new with cross_entity renders the account form in fixed (read-only) mode" do
    get new_account_url(locale: :en), params: {
      cross_entity: "1", fixed_type: "personal", fixed_currency: "", code_prefix: "610"
    }
    assert_response :success
    assert_match %r{value="610"}, response.body, "code pre-filled with the first 3 digits"
    assert_match %r{name="account\[account_type\]"}, response.body, "type submits (hidden)"
    # The hidden field carries the same id as the select, so an id-based
    # assertion passes whether or not the select was rendered. What this means
    # to assert is that the type is not EDITABLE, so it tests for the select tag
    # itself.
    assert_no_match %r{<select[^>]*name="account\[account_type\]"}, response.body,
                    "no editable type select"
    assert_no_match %r{account_tax_category_combined}, response.body, "tax field hidden"
  end

  test "create responds with account JSON for the cross-entity modal" do
    assert_difference("Account.count") do
      post accounts_url(locale: :en, format: :json), params: {
        account: { code: "610123", name: "Gift acct", account_type: "personal", currency: "", active: true }
      }
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "610123 - Gift acct", body["label"]
    assert_equal "10", body["entity"]
    assert_equal "personal", body["type"]
  end

  test "create returns JSON errors on invalid data" do
    assert_no_difference("Account.count") do
      post accounts_url(locale: :en, format: :json), params: {
        account: { code: "", name: "", account_type: "personal" }
      }
    end
    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["errors"].present?
  end

  test "should get edit" do
    get edit_account_url(locale: :en, id: @account)
    assert_response :success
  end

  test "should update account" do
    patch account_url(locale: :en, id: @account), params: { account: { name: "Updated Bank" } }
    assert_redirected_to accounts_url(locale: :en)
    @account.reload
    assert_equal "Updated Bank", @account.name
  end

  # audit M3: @account (bank_gbp) carries a fixture balance, so unticking Active
  # is refused inline and the account stays active.
  test "cannot deactivate an account that still holds a balance" do
    assert @account.balance.nonzero?, "fixture precondition: bank_gbp has a balance"
    patch account_url(locale: :en, id: @account), params: { account: { active: "0" } }
    assert_response :unprocessable_entity
    assert @account.reload.active?
  end

  test "should destroy account without postings" do
    account_without_postings = accounts(:inactive_account)
    assert_difference("Account.count", -1) do
      delete account_url(locale: :en, id: account_without_postings)
    end
    assert_redirected_to accounts_url(locale: :en)
  end

  test "destroy fails for account with postings" do
    # @account has postings from fixtures
    assert_no_difference("Account.count") do
      delete account_url(locale: :en, id: @account)
    end
    assert_redirected_to accounts_url(locale: :en)
  end

  # ==================== Ledger Tests ====================

  test "should get ledger" do
    get ledger_account_url(locale: :en, id: @account)
    assert_response :success
  end

  test "ledger filters by date range" do
    get ledger_account_url(locale: :en, id: @account), params: {
      start_date: Date.current.beginning_of_month,
      end_date: Date.current
    }
    assert_response :success
  end

  test "ledger exports csv" do
    get ledger_account_url(locale: :en, id: @account, format: :csv)
    assert_response :success
    assert_equal "text/csv", response.content_type.split(";").first
  end

  test "ledger shows running balance for balance sheet accounts" do
    get ledger_account_url(locale: :en, id: @account)
    assert_response :success
    assert_select "th", text: /balance/i
  end

  test "ledger running balances are in cents not display amounts" do
    # bank_gbp total balance = 11500 cents = £115.00
    # If calculate_running_balances divides by 100, format_amount_signed divides
    # again → £1.15
    get ledger_account_url(locale: :en, id: @account)
    assert_response :success
    assert_match(/115\.00/, response.body)
    assert_no_match(/£1\.15/, response.body)
  end

  # ==================== Balance At Tests ====================

  test "balance_at returns json with balance and currency" do
    get balance_at_account_url(locale: :en, id: @account),
        params: { date: Date.current.to_s },
        as: :json
    assert_response :success
    data = JSON.parse(response.body)
    assert data.key?("balance_cents")
    assert_equal @account.currency, data["currency"]
  end

  test "balance_at returns bad_request for invalid date" do
    get balance_at_account_url(locale: :en, id: @account),
        params: { date: "not-a-date" },
        as: :json
    assert_response :bad_request
  end

  test "balance_at balance matches account balance method" do
    date = Date.current
    get balance_at_account_url(locale: :en, id: @account),
        params: { date: date.to_s },
        as: :json
    assert_response :success
    data = JSON.parse(response.body)
    assert_equal @account.balance(end_date: date), data["balance_cents"]
  end

  # ==================== Save Deduction Percentage Tests ====================

  test "save_deduction_percentage updates account with valid percentage" do
    patch save_deduction_percentage_account_url(locale: :en, id: @expense),
          params: { deduction_percentage: 40 },
          as: :json
    assert_response :success
    data = JSON.parse(response.body)
    assert data["ok"]
    assert_equal 40, @expense.reload.deduction_percentage
  end

  test "save_deduction_percentage accepts boundary values 1 and 99" do
    patch save_deduction_percentage_account_url(locale: :en, id: @expense),
          params: { deduction_percentage: 1 },
          as: :json
    assert_response :success
    assert_equal 1, @expense.reload.deduction_percentage

    patch save_deduction_percentage_account_url(locale: :en, id: @expense),
          params: { deduction_percentage: 99 },
          as: :json
    assert_response :success
    assert_equal 99, @expense.reload.deduction_percentage
  end

  test "save_deduction_percentage rejects 0" do
    patch save_deduction_percentage_account_url(locale: :en, id: @expense),
          params: { deduction_percentage: 0 },
          as: :json
    assert_response :unprocessable_entity
  end

  test "save_deduction_percentage rejects 100" do
    patch save_deduction_percentage_account_url(locale: :en, id: @expense),
          params: { deduction_percentage: 100 },
          as: :json
    assert_response :unprocessable_entity
  end

  test "save_deduction_percentage rejects out of range values" do
    patch save_deduction_percentage_account_url(locale: :en, id: @expense),
          params: { deduction_percentage: 150 },
          as: :json
    assert_response :unprocessable_entity
  end

  # ==================== Deposit Tests ====================

  test "should get new deposit" do
    get new_deposit_account_url(locale: :en, id: @account)
    assert_response :success
  end

  test "should create simple deposit" do
    assert_difference("Posting.count", 2) do
      post create_deposit_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Test deposit",
          postings_attributes: {
            "0" => { account_id: @income.id, amount_display: "100.00", entry_type: "credit" }
          }
        },
        amount_display: "100.00"
      }
    end
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "should create deposit with multiple income sources" do
    assert_difference("Posting.count", 3) do
      post create_deposit_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Multiple income deposit",
          postings_attributes: {
            "0" => { account_id: @income.id, amount_display: "80.00", entry_type: "credit" },
            "1" => { account_id: accounts(:income_interest).id, amount_display: "20.00", entry_type: "credit" }
          }
        },
        amount_display: "100.00"
      }
    end
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "should create deposit with fees (positive and negative amounts)" do
    assert_difference("Posting.count", 3) do
      post create_deposit_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Deposit with fees",
          postings_attributes: {
            "0" => { account_id: @income.id, amount_display: "100.00", entry_type: "credit" },
            "1" => { account_id: @expense_fees.id, amount_display: "5.00", entry_type: "debit" }
          }
        },
        amount_display: "95.00"
      }
    end
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "create deposit fails without amount" do
    assert_no_difference("Posting.count") do
      post create_deposit_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "No amount",
          postings_attributes: {
            "0" => { account_id: @income.id, amount_display: "", entry_type: "credit" }
          }
        },
        amount_display: ""
      }
    end
    assert_response :unprocessable_entity
  end

  test "should get edit deposit" do
    entry = journal_entries(:posted_deposit)
    get edit_deposit_account_url(locale: :en, id: @account, journal_entry_id: entry.id)
    assert_response :success
  end

  test "should update deposit amount" do
    entry = journal_entries(:posted_deposit)
    patch update_deposit_account_url(locale: :en, id: @account, journal_entry_id: entry.id), params: {
      journal_entry: {
        entry_date: Date.current,
        memo: "Updated deposit",
        postings_attributes: {
          "0" => { account_id: @income.id, amount_display: "200.00", entry_type: "credit" }
        }
      },
      amount_display: "200.00"
    }
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "should update deposit with negative amount (fee deduction)" do
    entry = journal_entries(:multi_posting_deposit)
    patch update_deposit_account_url(locale: :en, id: @account, journal_entry_id: entry.id), params: {
      journal_entry: {
        entry_date: Date.current,
        memo: "Updated with fees",
        postings_attributes: {
          "0" => { account_id: @income.id, amount_display: "100.00", entry_type: "credit" },
          "1" => { account_id: @expense_fees.id, amount_display: "10.00", entry_type: "debit" }
        }
      },
      amount_display: "90.00"
    }
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "should get copy deposit" do
    entry = journal_entries(:posted_deposit)
    get copy_deposit_account_url(locale: :en, id: @account, journal_entry_id: entry.id)
    assert_response :success
  end

  test "copy deposit sets current date" do
    entry = journal_entries(:posted_deposit)
    get copy_deposit_account_url(locale: :en, id: @account, journal_entry_id: entry.id)
    assert_response :success
  end

  # ==================== Withdrawal Tests ====================

  test "should get new withdrawal" do
    get new_withdrawal_account_url(locale: :en, id: @account)
    assert_response :success
  end

  test "should create simple withdrawal" do
    assert_difference("Posting.count", 2) do
      post create_withdrawal_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Test withdrawal",
          postings_attributes: {
            "0" => { account_id: @expense.id, amount_display: "50.00", entry_type: "debit" }
          }
        },
        amount_display: "50.00"
      }
    end
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "should create withdrawal with multiple expenses" do
    assert_difference("JournalEntry.count") do
      post create_withdrawal_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Multiple expenses",
          postings_attributes: {
            "0" => { account_id: @expense.id, amount_display: "30.00", entry_type: "debit" },
            "1" => { account_id: @expense_fees.id, amount_display: "20.00", entry_type: "debit" }
          }
        },
        amount_display: "50.00"
      }
    end
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "should create withdrawal with refund (negative expense)" do
    assert_difference("JournalEntry.count") do
      post create_withdrawal_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Withdrawal with refund",
          postings_attributes: {
            "0" => { account_id: @expense.id, amount_display: "100.00", entry_type: "debit" },
            "1" => { account_id: @income.id, amount_display: "10.00", entry_type: "credit" }
          }
        },
        amount_display: "90.00"
      }
    end
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "should get edit withdrawal" do
    entry = journal_entries(:posted_withdrawal)
    get edit_withdrawal_account_url(locale: :en, id: @account, journal_entry_id: entry.id)
    assert_response :success
  end

  test "should update withdrawal amount" do
    entry = journal_entries(:posted_withdrawal)
    patch update_withdrawal_account_url(locale: :en, id: @account, journal_entry_id: entry.id), params: {
      journal_entry: {
        entry_date: Date.current,
        memo: "Updated withdrawal",
        postings_attributes: {
          "0" => { account_id: @expense.id, amount_display: "75.00", entry_type: "debit" }
        }
      },
      amount_display: "75.00"
    }
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "should get copy withdrawal" do
    entry = journal_entries(:posted_withdrawal)
    get copy_withdrawal_account_url(locale: :en, id: @account, journal_entry_id: entry.id)
    assert_response :success
  end

  # ==================== Transfer Tests ====================

  test "should get new transfer" do
    get new_transfer_account_url(locale: :en, id: @account)
    assert_response :success
  end

  test "should create transfer between bank accounts" do
    assert_difference("Posting.count", 2) do
      post create_transfer_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Transfer to secondary",
          from_account_id: @account.id,
          to_account_id: accounts(:bank_gbp_two).id,
          transfer_amount_display: "50.00"
        }
      }
    end
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  # A cross-currency transfer IS its own rate, bank spread and all, so the
  # server never blocks an implausible one — it saves and auto-posts. The
  # transfer form warns on submit in JS, but that is advisory. If this ever
  # starts 4xx-ing, a server-side rate check has crept in and broken the design.
  test "a cross-currency transfer with an implausible rate still saves and posts" do
    assert_difference("Posting.count", 2) do
      post create_transfer_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Fat-fingered rate",
          from_account_id: @account.id,
          to_account_id: @bank_eur.id,
          transfer_amount_display: "100.00",
          target_amount_display: "99999.00"
        }
      }
    end
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
    je = JournalEntry.order(:created_at).last
    assert je.posted?, "a cross-currency transfer auto-posts whatever the implied rate"
    assert_equal [ 10_000, 9_999_900 ], je.postings.pluck(:amount).sort
  end

  test "create transfer fails without to account" do
    assert_no_difference("Posting.count") do
      post create_transfer_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Missing to account",
          from_account_id: @account.id,
          to_account_id: "",
          transfer_amount_display: "50.00"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create transfer fails with same from and to account" do
    assert_no_difference("Posting.count") do
      post create_transfer_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Same account transfer",
          from_account_id: @account.id,
          to_account_id: @account.id,
          transfer_amount_display: "50.00"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create transfer fails with zero amount" do
    assert_no_difference("Posting.count") do
      post create_transfer_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Zero amount",
          from_account_id: @account.id,
          to_account_id: @daughter_bank.id,
          transfer_amount_display: "0.00"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "should get edit transfer" do
    entry = journal_entries(:posted_transfer)
    get edit_transfer_account_url(locale: :en, id: @account, journal_entry_id: entry.id)
    assert_response :success
  end

  test "should update transfer amount" do
    entry = journal_entries(:posted_transfer)
    patch update_transfer_account_url(locale: :en, id: @account, journal_entry_id: entry.id), params: {
      journal_entry: {
        entry_date: Date.current,
        memo: "Updated transfer",
        from_account_id: @account.id,
        to_account_id: accounts(:bank_gbp_two).id,
        transfer_amount_display: "75.00"
      }
    }
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end


  test "should update transfer accounts" do
    entry = journal_entries(:posted_transfer)
    patch update_transfer_account_url(locale: :en, id: @account, journal_entry_id: entry.id), params: {
      journal_entry: {
        entry_date: Date.current,
        memo: "Changed destination to EUR",
        from_account_id: @account.id,
        to_account_id: @bank_eur.id,  # GBP to EUR (cross-currency)
        transfer_amount_display: "30.00",
        target_amount_display: "35.00"  # What was received in EUR
      }
    }
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end

  test "should update transfer same currency" do
    entry = journal_entries(:posted_transfer)
    patch update_transfer_account_url(locale: :en, id: @account, journal_entry_id: entry.id), params: {
      journal_entry: {
        entry_date: Date.current,
        memo: "Changed destination",
        from_account_id: @account.id,
        to_account_id: accounts(:bank_gbp_two).id,
        transfer_amount_display: "30.00"
      }
    }
    assert_redirected_to ledger_account_url(locale: :en, id: @account)
  end
  
  test "should get copy transfer" do
    entry = journal_entries(:posted_transfer)
    get copy_transfer_account_url(locale: :en, id: @account, journal_entry_id: entry.id)
    assert_response :success
  end

  # copy_transfer only ever grabs the FIRST credit and FIRST debit posting —
  # fine for a true two-leg transfer, silent data loss for anything bigger. An
  # entry with three or more balance accounts and no nominal, allowed on purpose
  # for a pro, must be routed to the general duplicate instead, which copies
  # every posting.
  test "copy_transfer redirects to duplicate for an entry with more than 2 balance accounts" do
    entry = JournalEntry.new(entry_date: Date.current, memo: "Three-way split", posted: true)
    entry.postings.build(account: @account,                    entry_type: :debit,  amount: 30_000, currency: "GBP")
    entry.postings.build(account: accounts(:bank_gbp_two),     entry_type: :credit, amount: 10_000, currency: "GBP")
    entry.postings.build(account: accounts(:accounts_payable), entry_type: :credit, amount: 20_000, currency: "GBP")
    entry.save!

    get copy_transfer_account_url(locale: :en, id: @account, journal_entry_id: entry.id)

    assert_redirected_to duplicate_journal_entry_url(entry, locale: :en)
  end

  test "copy transfer preserves accounts and amount" do
    entry = journal_entries(:posted_transfer)
    get copy_transfer_account_url(locale: :en, id: @account, journal_entry_id: entry.id)
    assert_response :success
  end

  # ==================== Edge Cases ====================

  test "deposit that becomes withdrawal due to negative net" do
    assert_difference("JournalEntry.count") do
      post create_deposit_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Fees exceed income",
          postings_attributes: {
            "0" => { account_id: @income.id, amount_display: "10.00", entry_type: "credit" },
            "1" => { account_id: @expense_fees.id, amount_display: "15.00", entry_type: "debit" }
          }
        },
        amount_display: "-5.00"
      }
    end
  end

  test "handles personal account in withdrawal" do
    assert_difference("JournalEntry.count") do
      post create_withdrawal_account_url(locale: :en, id: @account), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "Personal withdrawal",
          postings_attributes: {
            "0" => { account_id: @personal.id, amount_display: "100.00", entry_type: "debit" }
          }
        },
        amount_display: "100.00"
      }
    end
  end

  test "handles EUR bank account" do
    assert_difference("JournalEntry.count") do
      post create_deposit_account_url(locale: :en, id: @bank_eur), params: {
        journal_entry: {
          entry_date: Date.current,
          memo: "EUR deposit",
          postings_attributes: {
            "0" => { account_id: @income.id, amount_display: "100.00", entry_type: "credit" }
          }
        },
        amount_display: "100.00"
      }
    end
  end

  # ==================== Tax category assignment (quick_map_tax)
  # ====================

  test "quick_map_tax assigns a gb_self_employment category to an account" do
    patch quick_map_tax_account_url(@income, locale: :en),
          params: { tax_category_combined: "gb_self_employment::sales_income" }
    assert_response :success
    @income.reload
    assert_equal "gb_self_employment", @income.tax_scheme
    assert_equal "sales_income", @income.tax_category_key
  end

  test "quick_map_tax assigns a gb_property category (second scheme) to an account" do
    patch quick_map_tax_account_url(@income, locale: :en),
          params: { tax_category_combined: "gb_property::rent_income" }
    assert_response :success
    @income.reload
    assert_equal "gb_property", @income.tax_scheme
    assert_equal "rent_income", @income.tax_category_key
  end

  # A blank category UNASSIGNS. It is what the × on a tax report page sends,
  # releasing the account so another scheme may claim it, since an account
  # belongs to exactly one scheme. It used to be rejected, back when the only
  # caller was the dashboard widget, which never sends one.
  test "quick_map_tax with a blank category releases the account" do
    @income.update!(tax_scheme: "gb_self_employment", tax_category_key: "rent_income")

    patch quick_map_tax_account_url(@income, locale: :en),
          params: { tax_category_combined: "" }

    assert_response :success
    @income.reload
    assert_nil @income.tax_category_key
    assert_nil @income.tax_scheme, "the scheme must be released too, not just the category"
  end
end
