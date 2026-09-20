# frozen_string_literal: true

require "test_helper"

class EntityPurgeServiceTest < ActiveSupport::TestCase
  setup do
    # Payer A (to be offboarded) and receiver B, joined by a cross-entity link:
    # A's drawings (601) ↔ B's capital (304), on two separate single-entity JEs.
    @a = Entity.create!(name: "Payer", code: "77", active: true,
                             orphaned_at: 11.years.ago, deletion_due_on: 1.year.ago)
    @b = Entity.create!(name: "Receiver", code: "78", active: true)

    a_bank = Account.create!(code: "177001", name: "A Bank", account_type: :asset, currency: "GBP", active: true)
    a_gift = Account.create!(code: "677001", name: "A Drawings", account_type: :personal, active: true)
    b_cap  = Account.create!(code: "378001", name: "B Capital", account_type: :equity, currency: "GBP", active: true)
    b_exp  = Account.create!(code: "578001", name: "B Expense", account_type: :expense, active: true)

    # JE₁ (A): Dr drawings 100 / Cr bank 100
    @je1 = JournalEntry.create!(entry_date: Date.current, posted: true, postings: [
      Posting.new(account: a_gift, amount: 100, entry_type: :debit),
      Posting.new(account: a_bank, amount: 100, entry_type: :credit, currency: "GBP")
    ])
    # JE₂ (B): Dr expense 100 / Cr capital 100
    @je2 = JournalEntry.create!(entry_date: Date.current, posted: true, postings: [
      Posting.new(account: b_exp, amount: 100, entry_type: :debit),
      Posting.new(account: b_cap, amount: 100, entry_type: :credit, currency: "GBP")
    ])

    link = SecureRandom.uuid
    @je1.postings.find { |p| p.account_id == a_gift.id }.update_column(:cross_entity_link_id, link)
    @je2.postings.find { |p| p.account_id == b_cap.id }.update_column(:cross_entity_link_id, link)
  end

  # Offboarding A must NOT cascade-delete the linked counterpart entry in B's
  # books. The purge deletes with delete_all, which skips
  # handle_cross_entity_link_on_destroy, so JE₂ survives with an inert link. If
  # the purge ever switches to .destroy, this fails loudly instead of silently
  # one-siding an active entity's books.
  test "purging an entity leaves its cross-entity counterpart entry intact" do
    EntityPurgeService.call(@a)

    assert_not JournalEntry.exists?(@je1.id), "the payer's JE should be purged"
    assert JournalEntry.exists?(@je2.id), "the receiver's linked JE must survive offboarding"
    assert_equal 2, @je2.reload.postings.count, "the receiver's postings are untouched"
  end

  # audit C3: the purge must also erase the entity's books archive and its
  # filed tax documents — not just the database rows.
  test "purging an entity erases its archive and filing objects, not just the DB" do
    Archives::Storage.upload(Archives::Storage.key_for(@a.code, 2024, year_end: true), "A's complete ledger 2024")
    Filing::Storage.upload("#{@a.code}/MTD/24-04-05-SA103-GB.html", "<html>A's return</html>")

    assert Archives::Storage.list(@a.code).any?
    assert_equal "<html>A's return</html>", Filing::Storage.fetch_html("#{@a.code}/MTD/24-04-05-SA103-GB.html")

    EntityPurgeService.call(@a)

    assert_empty Archives::Storage.list(@a.code), "the entity's books archive must be gone"
    assert_raises(Shrine::FileNotFound) { Filing::Storage.fetch_html("#{@a.code}/MTD/24-04-05-SA103-GB.html") }
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "archives", "77"))
    FileUtils.rm_rf(Rails.root.join("public", "tax_submissions", "77"))
  end
end
