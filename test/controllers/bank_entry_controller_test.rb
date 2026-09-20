# frozen_string_literal: true

require "test_helper"

# Deposit, withdrawal and transfer creation in AccountsController — the auto-
# balancing in create_bank_entry and recalculate_bank_posting, which is the most
# complex controller-level logic in the app.
class BankEntryControllerTest < ActionDispatch::IntegrationTest
  setup do
    @bank   = accounts(:bank_gbp)
    @bank_eur = accounts(:bank_eur)
    @income = accounts(:income_sales)
    @expense = accounts(:expenses_general)
    @admin  = admins(:two)
    sign_in_as(@admin)
  end

  # ==================== create_deposit ====================

  test "create_deposit builds a debit posting on the bank account" do
    post create_deposit_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @income.id, entry_type: "credit", amount_display: "100.00" }
        }
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    bank_posting = je.postings.find_by(account_id: @bank.id)
    assert bank_posting, "No posting created for bank account"
    assert bank_posting.debit?, "Bank posting should be a debit for a deposit"
    assert_equal 10000, bank_posting.amount
  end

  # ==================== cross-entity from a bank entry ====================

  test "create_withdrawal with a cross-entity leg builds the linked JE2" do
    link = SecureRandom.uuid
    assert_difference("JournalEntry.count", 2) do
      post create_withdrawal_account_url(@bank, locale: :en), params: {
        journal_entry: {
          entry_date: Date.current.to_s,
          postings_attributes: {
            # 601 gift (entity 10) — the bank line is auto-computed to balance
            # it
            "0" => { account_id: accounts(:personal_drawings).id, entry_type: "debit",
                     amount_display: "100", cross_entity_link_id: link }
          },
          cross_entity_entries: {
            "0" => { postings_attributes: {
              "0" => { account_id: accounts(:daughter_capital).id, entry_type: "credit",
                       amount_display: "100", cross_entity_link_id: link },
              "1" => { account_id: accounts(:daughter_expenses).id, entry_type: "debit",
                       amount_display: "100" }
            } }
          }
        }
      }
    end

    cap = Posting.find_by(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    assert cap, "linked JE2 capital created from a bank entry"
    assert cap.journal_entry.balanced?, "JE2 balances"
    assert Posting.exists?(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id),
           "the 601 gift in the bank entry carries the link"
  end

  test "create_deposit balances the journal entry" do
    post create_deposit_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @income.id, entry_type: "credit", amount_display: "250.00" }
        }
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    assert je.balanced?, "Journal entry should be balanced after create_deposit"
  end

  test "create_deposit with negative amount auto-converts to withdrawal" do
    # Entering a negative amount on a deposit flips the entry to withdrawal
    post create_deposit_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @income.id, entry_type: "credit", amount_display: "-50.00" }
        }
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    bank_posting = je.postings.find_by(account_id: @bank.id)
    assert bank_posting.credit?, "Negative deposit should produce a bank credit (withdrawal)"
  end

  test "create_deposit with multi-posting (split income and fees)" do
    post create_deposit_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @income.id,  entry_type: "credit", amount_display: "1000.00" },
          "1" => { account_id: @expense.id, entry_type: "debit",  amount_display: "50.00" }
        }
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    assert je.balanced?
    bank_posting = je.postings.find_by(account_id: @bank.id)
    # Net: credit 1000 - debit 50 = net credit 950, so bank debit should be 950
    assert_equal 95000, bank_posting.amount
    assert bank_posting.debit?
  end

  test "create_deposit fails with missing amount and re-renders form" do
    post create_deposit_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @income.id, entry_type: "credit", amount_display: "" }
        }
      }
    }

    assert_response :unprocessable_entity
  end

  # ==================== create_withdrawal ====================

  test "create_withdrawal builds a credit posting on the bank account" do
    post create_withdrawal_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @expense.id, entry_type: "debit", amount_display: "75.00" }
        }
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    bank_posting = je.postings.find_by(account_id: @bank.id)
    assert bank_posting.credit?, "Bank posting should be a credit for a withdrawal"
    assert_equal 7500, bank_posting.amount
  end

  test "create_withdrawal balances the journal entry" do
    post create_withdrawal_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @expense.id, entry_type: "debit", amount_display: "200.00" }
        }
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    assert JournalEntry.last.balanced?
  end

  test "create_withdrawal silently discards zero-amount posting rows" do
    post create_withdrawal_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @expense.id, entry_type: "debit", amount_display: "75.00" },
          "1" => { account_id: @expense.id, entry_type: "debit", amount_display: "0" }
        }
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    assert_equal 2, je.postings.count  # expense + bank only; zero row discarded
    assert je.balanced?
  end

  test "create_withdrawal with bank posting in params does not create duplicate bank posting" do
    post create_withdrawal_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @expense.id, entry_type: "debit", amount_display: "75.00" },
          "1" => { account_id: @bank.id, entry_type: "credit", amount_display: "75.00" }
        }
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    assert_equal 1, je.postings.where(account_id: @bank.id).count, "Expected exactly one bank posting"
    assert je.balanced?
  end

  test "create_withdrawal with negative amount auto-converts to deposit" do
    post create_withdrawal_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        postings_attributes: {
          "0" => { account_id: @expense.id, entry_type: "debit", amount_display: "-100.00" }
        }
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    bank_posting = je.postings.find_by(account_id: @bank.id)
    assert bank_posting.debit?, "Negative withdrawal should produce a bank debit (deposit)"
  end

  # ==================== create_transfer (same currency) ====================

  test "create_transfer same currency creates two balanced postings" do
    other_bank = accounts(:bank_gbp_two)

    post create_transfer_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        from_account_id: @bank.id,
        to_account_id: other_bank.id,
        transfer_amount_display: "300.00"
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    assert je.balanced?
    assert_equal 2, je.postings.count
    assert je.postings.find_by(account_id: @bank.id)&.credit?
    assert je.postings.find_by(account_id: other_bank.id)&.debit?
  end

  test "create_transfer same currency uses same amount for both sides" do
    other_bank = accounts(:bank_gbp_two)

    post create_transfer_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        from_account_id: @bank.id,
        to_account_id: other_bank.id,
        transfer_amount_display: "500.00"
      }
    }

    je = JournalEntry.last
    amounts = je.postings.pluck(:amount).uniq
    assert_equal [50000], amounts
  end

  # ==================== create_transfer (cross-currency) ====================

  test "create_transfer cross-currency uses target_amount for destination" do
    post create_transfer_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        from_account_id: @bank.id,
        to_account_id: @bank_eur.id,
        transfer_amount_display: "1000.00",
        target_amount_display: "1150.00"
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    je = JournalEntry.last
    assert_equal 2, je.postings.count

    gbp_posting = je.postings.find_by(currency: "GBP")
    eur_posting = je.postings.find_by(currency: "EUR")

    assert_equal 100000, gbp_posting.amount
    assert_equal 115000, eur_posting.amount
    assert gbp_posting.credit?
    assert eur_posting.debit?
  end

  test "create_transfer fails without from_account" do
    post create_transfer_account_url(@bank, locale: :en), params: {
      journal_entry: {
        entry_date: Date.current.to_s,
        to_account_id: @bank_eur.id,
        transfer_amount_display: "100.00"
      }
    }

    assert_response :unprocessable_entity
  end

  # ==================== update_deposit (recalculate_bank_posting)
  # ====================

  test "update_deposit recalculates bank posting amount" do
    je = journal_entries(:posted_deposit)

    patch update_deposit_account_url(@bank, locale: :en), params: {
      journal_entry_id: je.id,
      journal_entry: {
        entry_date: je.entry_date.to_s,
        postings_attributes: je.postings
          .where.not(account_id: @bank.id)
          .map.with_index { |p, i|
            [i.to_s, { id: p.id, account_id: p.account_id,
                       entry_type: p.entry_type, amount_display: "150.00" }]
          }.to_h
      }
    }

    assert_redirected_to ledger_account_url(@bank, locale: :en)
    bank_posting = je.reload.postings.find_by(account_id: @bank.id)
    assert_equal 15000, bank_posting.amount
  end

  test "update_deposit with all visible postings marked for deletion deletes the entry" do
    je = journal_entries(:posted_deposit)
    assert_difference("JournalEntry.count", -1) do
      patch update_deposit_account_url(@bank, locale: :en), params: {
        journal_entry_id: je.id,
        journal_entry: {
          entry_date: je.entry_date.to_s,
          postings_attributes: je.postings
            .where.not(account_id: @bank.id)
            .map.with_index { |p, i| [i.to_s, { id: p.id, _destroy: "1" }] }.to_h
        }
      }
    end
    assert_not JournalEntry.exists?(je.id), "emptied bank entry deleted (bank line alone can't stand)"
    assert_redirected_to ledger_account_url(@bank, locale: :en)
  end
end
