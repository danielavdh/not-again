# frozen_string_literal: true

require "test_helper"

# A journal entry submitted with cross_entity_entries builds each linked entry
# as a FULL journal entry with its own postings, all in one transaction. Admin
# `two` holds entity 10 (family_biz) and 04 (daughter); JE₁ is entity 10, the
# linked entry is entity 04.
class JournalEntriesCrossEntityTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:two)
    sign_in_as(@admin)
  end

  # JE₁ (entity 10): Dr 610 gift (bridge, carries link) / Cr 110 bank
  def je1_postings(link)
    {
      "0" => { account_id: accounts(:personal_drawings).id, amount_display: "100",
               entry_type: "debit", cross_entity_link_id: link },
      "1" => { account_id: accounts(:bank_gbp).id, amount_display: "100",
               entry_type: "credit" }
    }
  end

  # Linked entry (entity 04): Cr 304 capital (bridge, carries link) / Dr nominal
  def linked_postings(link, nominal:, nominal_amount: "100")
    {
      "0" => { account_id: accounts(:daughter_capital).id, amount_display: "100",
               entry_type: "credit", cross_entity_link_id: link },
      "1" => { account_id: nominal, amount_display: nominal_amount, entry_type: "debit" }
    }
  end

  def post_cross_entity(link, nominal:, nominal_amount: "100")
    post journal_entries_url(locale: :en), params: { journal_entry: {
      entry_date: "2026-03-10",
      postings_attributes: je1_postings(link),
      cross_entity_entries: { "0" => { postings_attributes: linked_postings(link, nominal: nominal, nominal_amount: nominal_amount) } }
    } }
  end

  test "a cross-entity entry builds and links a full counterpart JE₂" do
    link = SecureRandom.uuid
    assert_difference("JournalEntry.count", 2) do
      post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    end

    cap = Posting.find_by(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    assert cap, "capital posting linked in JE₂"
    assert cap.credit?
    je2 = cap.journal_entry
    assert je2.balanced?
    assert_equal 2, je2.postings.count
    assert_equal Date.new(2026, 3, 10), je2.entry_date, "JE₂ date synced to JE₁"
    assert Posting.exists?(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id),
           "JE₁'s 601 gift carries the same link"
  end

  test "two linked entries (JE₂ + JE₃) from one JE₁" do
    l1 = SecureRandom.uuid
    l2 = SecureRandom.uuid
    assert_difference("JournalEntry.count", 3) do
      post journal_entries_url(locale: :en), params: { journal_entry: {
        entry_date: "2026-03-10",
        postings_attributes: {
          "0" => { account_id: accounts(:personal_drawings).id, amount_display: "100", entry_type: "debit", cross_entity_link_id: l1 },
          "1" => { account_id: accounts(:personal_drawings).id, amount_display: "60",  entry_type: "debit", cross_entity_link_id: l2 },
          "2" => { account_id: accounts(:bank_gbp).id,          amount_display: "160", entry_type: "credit" }
        },
        cross_entity_entries: {
          "0" => { postings_attributes: linked_postings(l1, nominal: accounts(:daughter_expenses).id) },
          "1" => { postings_attributes: {
            "0" => { account_id: accounts(:daughter_capital).id,  amount_display: "60", entry_type: "credit", cross_entity_link_id: l2 },
            "1" => { account_id: accounts(:daughter_expenses).id, amount_display: "60", entry_type: "debit" }
          } }
        }
      } }
    end
    assert Posting.exists?(cross_entity_link_id: l1)
    assert Posting.exists?(cross_entity_link_id: l2)
  end

  test "a failing linked entry rolls back JE₁ too (one transaction)" do
    link = SecureRandom.uuid
    assert_no_difference("JournalEntry.count") do
      # linked entry doesn't balance (capital 100, nominal 50) → JE₂ invalid →
      # rollback
      post_cross_entity(link, nominal: accounts(:daughter_expenses).id, nominal_amount: "50")
    end
    assert_response :unprocessable_entity
    assert_nil Posting.find_by(cross_entity_link_id: link), "JE₁'s bridge rolled back too"
  end

  test "account options carry the cross-entity trigger data attributes" do
    get edit_journal_entry_url(locale: :en, id: journal_entries(:draft_entry))
    assert_response :success
    assert_match(/data-entity=/, response.body)
    assert_match(/data-group=/, response.body)
    assert_match(/data-type=/, response.body)
  end

  test "cross_entity_rows renders namespaced posting inputs for a linked entry" do
    get cross_entity_rows_journal_entries_url(locale: :en), params: {
      entry_index: "1784", link_id: SecureRandom.uuid, gift_side: "debit", amount: "100",
      capital_account_id: accounts(:daughter_capital).id,
      nominal_account_id: accounts(:daughter_expenses).id
    }
    assert_response :success
    # capital posting (index 17840): carries the link
    assert_match %r{name="journal_entry\[cross_entity_entries\]\[1784\]\[postings_attributes\]\[17840\]\[account_id\]"}, response.body
    assert_match %r{name="journal_entry\[cross_entity_entries\]\[1784\]\[postings_attributes\]\[17840\]\[cross_entity_link_id\]"}, response.body
    # nominal posting (index 17841): no link
    assert_match %r{name="journal_entry\[cross_entity_entries\]\[1784\]\[postings_attributes\]\[17841\]\[account_id\]"}, response.body
    assert_equal 2, response.body.scan(/ce-mirror-row/).size, "two mirror rows"
    # the nominal row (index 17841) carries the receipt widget with its unique
    # index
    assert_match %r{data-posting-index="17841"}, response.body, "receipt widget on the nominal leg"
    # the receipt scan must nest INSIDE the nominal posting (not directly under
    # postings_attributes)
    assert_match %r{name="journal_entry\[cross_entity_entries\]\[1784\]\[postings_attributes\]\[17841\]\[receipts_attributes\]\[0\]\[scan\]"}, response.body,
                 "receipt nested inside the posting index"
    assert_match /ce-mirror-side/, response.body, "JE context shows the entry_type column"
  end

  test "cross_entity_rows omits the entry_type column in a bank context" do
    get cross_entity_rows_journal_entries_url(locale: :en), params: {
      entry_index: "1784", link_id: SecureRandom.uuid, gift_side: "debit", amount: "100", context: "bank",
      capital_account_id: accounts(:daughter_capital).id,
      nominal_account_id: accounts(:daughter_expenses).id
    }
    assert_response :success
    assert_no_match /ce-mirror-side/, response.body, "bank context hides the entry_type column"
    # but the side still submits via the hidden field
    assert_match %r{\[postings_attributes\]\[17840\]\[entry_type\]}, response.body
  end

  test "an unbalanced JE re-renders the cross-entity mirror rows from params" do
    link = SecureRandom.uuid
    post journal_entries_url(locale: :en), params: { journal_entry: {
      entry_date: "2026-03-10",
      postings_attributes: {
        "0" => { account_id: accounts(:personal_drawings).id, amount_display: "100", entry_type: "debit", cross_entity_link_id: link },
        "1" => { account_id: accounts(:bank_gbp).id, amount_display: "50", entry_type: "credit" } # doesn't balance
      },
      cross_entity_entries: { "1784" => { postings_attributes: {
        "17840" => { account_id: accounts(:daughter_capital).id, amount_display: "100", entry_type: "credit", cross_entity_link_id: link },
        "17841" => { account_id: accounts(:daughter_expenses).id, amount_display: "100", entry_type: "debit" }
      } } }
    } }
    assert_response :unprocessable_entity
    assert_match(/ce-mirror-row/, response.body, "mirror rows re-drawn, not lost")
    # re-rendered with the same namespacing so they round-trip on resubmit
    assert_match %r{cross_entity_entries\]\[1784\]\[postings_attributes\]\[17840\]\[account_id\]}, response.body
    # the 601 gift (JE₁ posting 0) amount is locked — modal-driven only (order-
    # agnostic)
    assert_match %r{<input(?=[^>]*\[postings_attributes\]\[0\]\[amount_display\])(?=[^>]*readonly)[^>]*>}, response.body,
                 "gift amount rendered readonly"
  end

  # --- #3 deletion --------------------------------------------------------

  test "deleting a cross-entity ORIGIN cascades to its counterpart JE₂ (and the link)" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry
    je2 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry
    je1.unpost! # must be unposted to delete; JE₂ stays posted → cascade deletes it anyway

    assert_difference("JournalEntry.count", -2) do
      delete journal_entry_url(locale: :en, id: je1)
    end
    assert_not JournalEntry.exists?(je1.id)
    assert_not JournalEntry.exists?(je2.id), "counterpart JE₂ cascaded even though posted"
    assert_not Posting.exists?(cross_entity_link_id: link), "link gone"
  end

  test "deleting a cross-entity COUNTERPART severs the link but leaves the origin" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    gift = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id)
    je1  = gift.journal_entry
    je2  = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry
    je2.unpost!

    assert_difference("JournalEntry.count", -1) do
      delete journal_entry_url(locale: :en, id: je2)
    end
    assert JournalEntry.exists?(je1.id), "origin JE₁ untouched"
    assert_not JournalEntry.exists?(je2.id)
    assert_nil gift.reload.cross_entity_link_id, "601 gift link severed → plain gift"
  end

  test "a leg ticked away (all postings _destroy) saves JE₁ with no JE₂ built" do
    link = SecureRandom.uuid
    assert_difference("JournalEntry.count", 1) do # only JE₁
      post journal_entries_url(locale: :en), params: { journal_entry: {
        entry_date: "2026-03-10",
        postings_attributes: {
          "0" => { account_id: accounts(:bank_gbp).id, amount_display: "100", entry_type: "debit" },
          "1" => { account_id: accounts(:income_sales).id, amount_display: "100", entry_type: "credit" }
        },
        cross_entity_entries: { "1784" => { postings_attributes: {
          "17840" => { account_id: accounts(:daughter_capital).id, amount_display: "100", entry_type: "credit", cross_entity_link_id: link, _destroy: "1" },
          "17841" => { account_id: accounts(:daughter_expenses).id, amount_display: "100", entry_type: "debit", _destroy: "1" }
        } } }
      } }
    end
    assert_not Posting.exists?(cross_entity_link_id: link), "the emptied leg built no JE₂"
  end

  test "a REJECTED gift deletion (leaves JE₁ invalid) does NOT cascade-delete JE₂" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    gift = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id)
    je1  = gift.journal_entry
    bank = je1.postings.find { |p| p.account_id == accounts(:bank_gbp).id }
    je2  = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry
    je1.unpost!

    # Mark the gift for deletion, leaving only the (unbalanced) bank line → JE₁
    # save is rejected.
    assert_no_difference("JournalEntry.count") do
      patch journal_entry_url(locale: :en, id: je1), params: { journal_entry: {
        postings_attributes: {
          "0" => { id: gift.id, _destroy: "1" },
          "1" => { id: bank.id, account_id: accounts(:bank_gbp).id, amount_display: "100", entry_type: "credit" }
        }
      } }
    end
    assert Posting.exists?(gift.id), "gift NOT deleted (save rejected)"
    assert JournalEntry.exists?(je2.id), "JE₂ must survive while the gift deletion is rejected"
    assert_equal link, gift.reload.cross_entity_link_id, "link intact"
  end

  test "emptying a cross-entity JE₁ (all postings marked) deletes it and cascades JE₂" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    gift = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id)
    je1  = gift.journal_entry
    bank = je1.postings.find { |p| p.account_id == accounts(:bank_gbp).id }
    je2  = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry

    assert_difference("JournalEntry.count", -2) do # JE₁ + its cascaded JE₂
      patch journal_entry_url(locale: :en, id: je1), params: { journal_entry: {
        postings_attributes: {
          "0" => { id: gift.id, _destroy: "1" },
          "1" => { id: bank.id, _destroy: "1" }
        }
      } }
    end
    assert_not JournalEntry.exists?(je1.id)
    assert_not JournalEntry.exists?(je2.id), "JE₂ cascaded when JE₁ was emptied"
  end

  # --- #4 edit a persisted cross-entity JE --------------------------------

  test "JE₁'s edit page renders the persisted JE₂ mirror rows carrying their posting ids" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry
    cap = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)

    get edit_journal_entry_url(locale: :en, id: je1)
    assert_response :success
    assert_match(/ce-mirror-row/, response.body, "JE₂ mirror rows shown on edit")
    # the capital row (index <je2.id>0) carries its persisted id → an edit
    # UPDATES, not duplicates
    assert_match %r{name="journal_entry\[cross_entity_entries\]\[#{cap.journal_entry_id}\]\[postings_attributes\]\[#{cap.journal_entry_id}0\]\[id\]"}, response.body
  end

  test "editing a persisted leg UPDATES the existing JE₂ (no duplicate)" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    cap = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    je2 = cap.journal_entry
    nom = je2.postings.detect { |p| p.id != cap.id }
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry

    assert_no_difference("JournalEntry.count") do
      patch journal_entry_url(locale: :en, id: je1), params: { journal_entry: {
        cross_entity_entries: { je2.id.to_s => { postings_attributes: {
          "0" => { id: cap.id, account_id: cap.account_id, amount_display: "100", entry_type: "credit", cross_entity_link_id: link },
          "1" => { id: nom.id, account_id: nom.account_id, amount_display: "100", entry_type: "debit", description: "edited note" }
        } } }
      } }
    end
    assert_equal "edited note", nom.reload.description
    assert_equal je2.id, cap.reload.journal_entry_id, "same JE₂ updated, not duplicated"
  end

  test "marking a persisted leg for deletion on JE₁'s edit destroys JE₂ and severs the gift" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    cap  = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    je2  = cap.journal_entry
    nom  = je2.postings.detect { |p| p.id != cap.id }
    gift = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id)
    je1  = gift.journal_entry

    assert_difference("JournalEntry.count", -1) do
      patch journal_entry_url(locale: :en, id: je1), params: { journal_entry: {
        cross_entity_entries: { je2.id.to_s => { postings_attributes: {
          "0" => { id: cap.id, _destroy: "1" },
          "1" => { id: nom.id, _destroy: "1" }
        } } }
      } }
    end
    assert_not JournalEntry.exists?(je2.id), "JE₂ destroyed"
    assert JournalEntry.exists?(je1.id), "JE₁ survives"
    assert_nil gift.reload.cross_entity_link_id, "gift severed → plain posting"
  end

  test "cross_entity_rows renders the persisted leg's REAL postings (receipt widget by posting-id)" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    cap = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    nom = cap.journal_entry.postings.detect { |p| p.id != cap.id }

    get cross_entity_rows_journal_entries_url(locale: :en), params: {
      entry_index: "9999", link_id: link, gift_side: "debit", amount: "100",
      capital_account_id: cap.account_id, nominal_account_id: nom.account_id,
      capital_posting_id: cap.id, nominal_posting_id: nom.id
    }
    assert_response :success
    # the real posting ids are carried → the save UPDATES in place
    assert_match %r{value="#{cap.id}"}, response.body
    assert_match %r{value="#{nom.id}"}, response.body
    # the nominal row uses the PERSISTED receipt widget (keyed by posting-id,
    # always shows add/link)
    assert_match %r{data-posting-id="#{nom.id}"}, response.body
  end

  # Regression for the real modal-edit param shape: a FRESH (Date.now)
  # entry_index
  # but the JE₂ posting ids carried → must UPDATE the existing JE₂, never
  # duplicate.
  test "modal-edit params (fresh entry_index + posting ids) update JE₂, not duplicate" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    cap = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    je2 = cap.journal_entry
    nom = je2.postings.detect { |p| p.id != cap.id }
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry

    fresh = "1784790144263" # a Date.now()-style key, NOT je2.id
    assert_no_difference("JournalEntry.count") do
      patch journal_entry_url(locale: :en, id: je1), params: { journal_entry: {
        cross_entity_entries: { fresh => { postings_attributes: {
          "#{fresh}0" => { id: cap.id, account_id: cap.account_id, amount_display: "100", entry_type: "credit", cross_entity_link_id: link },
          "#{fresh}1" => { id: nom.id, account_id: nom.account_id, amount_display: "100", entry_type: "debit", description: "changed via modal" }
        } } }
      } }
    end
    assert_equal je2.id, cap.reload.journal_entry_id, "same JE₂, no duplicate created"
    assert_equal "changed via modal", nom.reload.description
  end

  test "editing the coupled AMOUNT updates BOTH JE₁ and JE₂ (mid-transaction mirror guard)" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    gift = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id)
    je1  = gift.journal_entry
    bank = je1.postings.find { |p| p.account_id == accounts(:bank_gbp).id }
    cap  = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    je2  = cap.journal_entry
    nom  = je2.postings.detect { |p| p.id != cap.id }

    assert_no_difference("JournalEntry.count") do
      patch journal_entry_url(locale: :en, id: je1), params: { journal_entry: {
        postings_attributes: {
          "0" => { id: gift.id, account_id: gift.account_id, amount_display: "120", entry_type: "debit", cross_entity_link_id: link },
          "1" => { id: bank.id, account_id: bank.account_id, amount_display: "120", entry_type: "credit" }
        },
        cross_entity_entries: { je2.id.to_s => { postings_attributes: {
          "0" => { id: cap.id, account_id: cap.account_id, amount_display: "120", entry_type: "credit", cross_entity_link_id: link },
          "1" => { id: nom.id, account_id: nom.account_id, amount_display: "120", entry_type: "debit" }
        } } }
      } }
    end
    assert_redirected_to journal_entry_url(locale: :en, id: je1)
    assert_equal 12000, gift.reload.amount, "gift amount updated"
    assert_equal 12000, cap.reload.amount,  "capital mirror updated"
    assert_equal 12000, nom.reload.amount,  "nominal updated"
  end

  test "an invalid coupled edit re-renders (422) without crashing on id-bearing legs" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    gift = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id)
    je1  = gift.journal_entry
    bank = je1.postings.find { |p| p.account_id == accounts(:bank_gbp).id }
    cap  = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    je2  = cap.journal_entry
    nom  = je2.postings.detect { |p| p.id != cap.id }

    patch journal_entry_url(locale: :en, id: je1), params: { journal_entry: {
      postings_attributes: {
        "0" => { id: gift.id, account_id: gift.account_id, amount_display: "120", entry_type: "debit", cross_entity_link_id: link },
        "1" => { id: bank.id, account_id: bank.account_id, amount_display: "50", entry_type: "credit" } # unbalanced → JE₁ invalid
      },
      cross_entity_entries: { je2.id.to_s => { postings_attributes: {
        "0" => { id: cap.id, account_id: cap.account_id, amount_display: "120", entry_type: "credit", cross_entity_link_id: link },
        "1" => { id: nom.id, account_id: nom.account_id, amount_display: "120", entry_type: "debit" }
      } } }
    } }
    assert_response :unprocessable_entity
    assert_match(/ce-mirror-row/, response.body, "mirror rows re-rendered from id-bearing params, no 500")
  end

  test "editing a JE₂ redirects to JE₁'s edit (the single edit surface)" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry
    je2 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry

    get edit_journal_entry_url(locale: :en, id: je2)
    assert_redirected_to edit_journal_entry_url(locale: :en, id: je1)
  end

  test "editing a JE₂ via the BANK route (equity capital as balance acct) also redirects to JE₁" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry
    je2 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry

    get edit_withdrawal_account_url(accounts(:daughter_capital), locale: :en, journal_entry_id: je2.id)
    assert_redirected_to edit_journal_entry_url(locale: :en, id: je1)
  end

  # --- #7 show-page mirror + index cue ------------------------------------

  test "JE₁'s show page renders the linked JE₂'s postings (read-only mirror band)" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry
    je2 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry

    get journal_entry_url(locale: :en, id: je1)
    assert_response :success
    # structural, not tied to a CSS class: the counterpart's account + a link to
    # it
    assert_match(/#{accounts(:daughter_capital).code}/, response.body, "JE₂'s capital account shown in the band")
    assert_match %r{journal_entries/#{je2.id}}, response.body, "links to JE₂"
  end

  test "JE₂'s show page symmetrically renders JE₁'s postings" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry
    je2 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry

    get journal_entry_url(locale: :en, id: je2)
    assert_response :success
    assert_match(/#{accounts(:personal_drawings).code}/, response.body, "JE₁'s 601 gift shown in the band")
    assert_match %r{journal_entries/#{je1.id}}, response.body, "links back to JE₁"
  end

  test "the JE index flags cross-entity rows with the linked cue" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    get journal_entries_url(locale: :en)
    assert_response :success
    assert_match(/ce-linked-cue/, response.body)
  end

  # --- #8 copy -----------------------------------------------------------

  test "copying a cross-entity JE pre-fills the mirror band with a FRESH link (not the original's)" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry

    assert_no_difference("JournalEntry.count") do # the copy form is unsaved
      get duplicate_journal_entry_url(locale: :en, id: je1)
    end
    assert_response :success
    assert_match(/ce-mirror-row/, response.body, "copy pre-fills the JE₂ mirror band")
    assert_no_match(/#{link}/, response.body, "the original's link is NOT reused — a fresh one is minted")
  end

  test "copying a JE₂ counterpart redirects to copying the origin JE₁" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry
    je2 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry

    get duplicate_journal_entry_url(locale: :en, id: je2)
    assert_redirected_to duplicate_journal_entry_url(locale: :en, id: je1)
  end

  # --- post/unpost move the pair together (never unlink) ------------------

  test "unposting a cross-entity entry unposts its linked pair too, link intact" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry
    cap = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    je2 = cap.journal_entry
    assert je1.posted? && je2.posted?

    patch unpost_journal_entry_url(locale: :en, id: je1)
    assert_not je1.reload.posted?, "JE₁ unposted"
    assert_not je2.reload.posted?, "JE₂ unposted with it"
    assert_equal link, cap.reload.cross_entity_link_id, "unposting does NOT sever the link"
  end

  test "posting one side re-posts the whole pair (symmetric)" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:personal_drawings).id).journal_entry
    je2 = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id).journal_entry
    je1.unpost!; je2.unpost!

    patch post_journal_entry_url(locale: :en, id: je2) # post from the JE₂ side
    assert je2.reload.posted?, "JE₂ posted"
    assert je1.reload.posted?, "JE₁ re-posted with it"
  end

  # ---- what the counterpart's own side may see of the other family's books ----
  #
  # A cross-entity pair joins two SEPARATE consolidation groups, so the entry on
  # the far side belongs to books this admin has no relationship with. The mirror
  # band used to print its postings — account codes, names, descriptions and
  # amounts — to whoever could open either half.

  # admins(:one) holds personal and spouse, never family_biz, so JE₁ is not
  # theirs to read; a link to 04 makes JE₂ theirs.
  def admin_on_the_receiving_side_only
    AdminEntity.create!(admin: admins(:one), entity: entities(:daughter), access_level: :full_access)
    admins(:one)
  end

  test "the far side's postings are not printed to an admin who cannot read that entry" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je2 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:daughter_capital).id).journal_entry

    sign_in_as(admin_on_the_receiving_side_only)
    get journal_entry_url(locale: :en, id: je2)
    assert_response :success

    # It still SAYS there is a pair, and names the business and the number.
    assert_match I18n.t("entities.cross_entity.linked_entry"), response.body
    # But nothing of the other family's ledger.
    assert_no_match(/610001/, response.body, "the donor's gift account leaked")
    assert_no_match(/110001/, response.body, "the donor's bank account leaked")
    assert_select "a[href=?]", journal_entry_path(locale: :en, id: je2.cross_entity_linked_entries.first),
                  false, "and no link, which would 404 anyway"
  end

  test "an admin holding both sides still gets the detail, which is the useful case" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je2 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:daughter_capital).id).journal_entry

    get journal_entry_url(locale: :en, id: je2) # still admins(:two), holds 10 and 04
    assert_match(/610001/, response.body, "one bookkeeper holding both sides wants to see it")
  end

  # Editing JE₂ without JE₁ is refused and lands on JE₂'s show page. That
  # redirect was the one route into that page which dropped `from`/`account_id`,
  # so the way back offered the journal-entry index instead of the ledger.
  test "the refusal to edit a counterpart keeps the way back to the ledger" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je2 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:daughter_capital).id).journal_entry

    sign_in_as(admin_on_the_receiving_side_only)
    get edit_journal_entry_url(locale: :en, id: je2,
                               from: "ledger", account_id: accounts(:daughter_expenses).id)

    assert_redirected_to journal_entry_path(locale: :en, id: je2,
                                            from: "ledger",
                                            account_id: accounts(:daughter_expenses).id)
  end

  # ---- whose figures an unpost may move ----

  test "unposting one side leaves the other family's figures posted, and the link intact" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    cap = Posting.find_by!(cross_entity_link_id: link, account_id: accounts(:daughter_capital).id)
    je2 = cap.journal_entry
    je1 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:personal_drawings).id).journal_entry

    sign_in_as(admin_on_the_receiving_side_only)
    patch unpost_journal_entry_url(locale: :en, id: je2)

    assert_not je2.reload.posted?, "their own half is theirs to unpost"
    assert je1.reload.posted?,
           "the donor's gift must stay in the donor's posted figures"
    # Nothing severed: posted is a column, so posting again restores the pair.
    assert_equal link, cap.reload.cross_entity_link_id
    patch post_journal_entry_url(locale: :en, id: je2)
    assert je2.reload.posted?, "and it can be posted again"
  end

  test "a bookkeeper holding both sides still moves the pair together" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je2 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:daughter_capital).id).journal_entry
    je1 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:personal_drawings).id).journal_entry

    patch unpost_journal_entry_url(locale: :en, id: je2) # admins(:two) holds 10 and 04

    assert_not je2.reload.posted?
    assert_not je1.reload.posted?, "both halves are theirs, so both follow"
  end

  # ---- who may change a pair at all ----
  #
  # It takes both businesses to CREATE one (create refuses less), so it is never
  # one side's to alter alone. The receiving half is the exception, and not an
  # alteration: it is wholly inside their own books.

  # admins(:mixed) holds family_biz (10, the donor side) and nothing on 04.
  def admin_on_the_donor_side_only
    admins(:mixed)
  end

  test "the donor's half cannot be edited or deleted by someone without the other side" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:personal_drawings).id).journal_entry
    je2 = je1.cross_entity_linked_entries.first

    sign_in_as(admin_on_the_donor_side_only)

    get edit_journal_entry_url(locale: :en, id: je1)
    assert_redirected_to journal_entry_path(locale: :en, id: je1)
    # And so the other family's accounts never reach the page either.
    follow_redirect!
    assert_no_match(/304001/, response.body)

    je1.unpost!
    assert_no_difference("JournalEntry.count") do
      delete journal_entry_url(locale: :en, id: je1)
    end
    assert JournalEntry.exists?(je2.id), "and it cannot take the other business's entry with it"
  end

  test "the donor's half cannot be unposted by someone without the other side" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je1 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:personal_drawings).id).journal_entry

    sign_in_as(admin_on_the_donor_side_only)
    patch unpost_journal_entry_url(locale: :en, id: je1)

    assert je1.reload.posted?, "half of a joint transaction is not theirs alone to unpost"
  end

  # Giving the gift back: wholly inside the receiver's own books.
  test "the receiving half can be given back by its own side, and the donor keeps theirs" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je2 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:daughter_capital).id).journal_entry
    gift = Posting.find_by!(cross_entity_link_id: link,
                            account_id: accounts(:personal_drawings).id)

    sign_in_as(admin_on_the_receiving_side_only)
    patch unpost_journal_entry_url(locale: :en, id: je2)
    assert_difference("JournalEntry.count", -1) do
      delete journal_entry_url(locale: :en, id: je2)
    end

    assert JournalEntry.exists?(gift.journal_entry_id), "the donor's own entry stands"
    assert gift.journal_entry.reload.posted?, "and stays in their posted figures"
    assert_nil gift.reload.cross_entity_link_id, "the link dies with the half that was given back"
  end

  # But still not an EDIT: that would rewrite the shared transaction.
  test "the receiving half cannot be edited by its own side alone" do
    link = SecureRandom.uuid
    post_cross_entity(link, nominal: accounts(:daughter_expenses).id)
    je2 = Posting.find_by!(cross_entity_link_id: link,
                           account_id: accounts(:daughter_capital).id).journal_entry

    sign_in_as(admin_on_the_receiving_side_only)
    get edit_journal_entry_url(locale: :en, id: je2)
    assert_response :redirect
  end

  test "a plain JE with no cross-entity entries still saves normally" do
    assert_difference("JournalEntry.count", 1) do
      post journal_entries_url(locale: :en), params: { journal_entry: {
        entry_date: "2026-03-10",
        postings_attributes: {
          "0" => { account_id: accounts(:bank_gbp).id, amount_display: "100", entry_type: "debit" },
          "1" => { account_id: accounts(:income_sales).id, amount_display: "100", entry_type: "credit" }
        }
      } }
    end
  end
end
