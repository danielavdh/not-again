# frozen_string_literal: true

require "test_helper"

# A cross-entity transaction is two SEPARATE single-entity journal entries
# joined by a shared cross_entity_link_id on their bridge postings: the payer
# entity's drawings (6xx) and the receiver entity's capital (3xx). This tests
# the link lookups and the destroy-time sever, NOT the creation or deletion
# policy.
class CrossEntityLinkTest < ActiveSupport::TestCase
  def setup
    @link_id = SecureRandom.uuid

    # JE₁ — entity 01: Dr drawings(601) 100 / Cr bank(101) 100
    @je1 = JournalEntry.create!(entry_date: Date.current, postings: [
      Posting.new(account: accounts(:boss_drawings), amount: 10_000, entry_type: :debit),
      Posting.new(account: accounts(:boss_bank), amount: 10_000, entry_type: :credit, currency: "GBP")
    ])
    # JE₂ — entity 04: Dr expense(504) 100 / Cr capital(304) 100
    @je2 = JournalEntry.create!(entry_date: Date.current, postings: [
      Posting.new(account: accounts(:daughter_expenses), amount: 10_000, entry_type: :debit),
      Posting.new(account: accounts(:daughter_capital), amount: 10_000, entry_type: :credit, currency: "GBP")
    ])

    @bridge1 = @je1.postings.find { |p| p.account.code == "601001" } # drawings
    @bank1   = @je1.postings.find { |p| p.account.code == "101001" } # bank
    @bridge2 = @je2.postings.find { |p| p.account.code == "304001" } # capital

    @bridge1.update_column(:cross_entity_link_id, @link_id)
    @bridge2.update_column(:cross_entity_link_id, @link_id)

    # A plain, unlinked single-entity JE for the negative cases
    @plain = JournalEntry.create!(entry_date: Date.current, postings: [
      Posting.new(account: accounts(:bank_gbp), amount: 10_000, entry_type: :debit, currency: "GBP"),
      Posting.new(account: accounts(:income_sales), amount: 10_000, entry_type: :credit)
    ])
  end

  # --- Posting -----------------------------------------------------------

  test "cross_entity_linked? reflects the presence of a link" do
    assert @bridge1.cross_entity_linked?
    assert_not @bank1.cross_entity_linked?
    assert_not @plain.postings.first.cross_entity_linked?
  end

  test "cross_entity_counterpart returns the paired bridge posting both ways" do
    assert_equal @bridge2, @bridge1.cross_entity_counterpart
    assert_equal @bridge1, @bridge2.cross_entity_counterpart
  end

  test "cross_entity_counterpart is nil for an unlinked posting" do
    assert_nil @bank1.cross_entity_counterpart
  end

  # --- JournalEntry ------------------------------------------------------

  test "cross_entity? is true only when a posting carries a link" do
    assert @je1.reload.cross_entity?
    assert @je2.reload.cross_entity?
    assert_not @plain.reload.cross_entity?
  end

  test "cross_entity_linked_entries returns the counterpart JE both ways" do
    assert_equal [@je2.id], @je1.reload.cross_entity_linked_entries.pluck(:id)
    assert_equal [@je1.id], @je2.reload.cross_entity_linked_entries.pluck(:id)
  end

  test "cross_entity_linked_entries is empty for an unlinked JE" do
    assert_empty @plain.reload.cross_entity_linked_entries
  end

  # --- Destroy-time policy (ASYMMETRIC by side) --------------------------

  test "destroying the CAPITAL (equity) bridge only severs — JE₁ survives as a plain gift" do
    @bridge2.destroy

    assert_nil @bridge1.reload.cross_entity_link_id, "surviving gift should be unlinked"
    assert Posting.exists?(@bridge1.id), "the gift posting must NOT be destroyed"
    assert JournalEntry.exists?(@je1.id), "JE₁ must survive"
  end

  test "destroying the GIFT (personal) bridge cascades — the whole counterpart JE₂ is deleted" do
    @bridge1.destroy # the 601 gift/origin side, as a form _destroy would

    assert_not JournalEntry.exists?(@je2.id), "counterpart JE₂ cascaded away"
    assert_not Posting.exists?(@bridge2.id), "its capital posting is gone"
    assert JournalEntry.exists?(@je1.id), "JE₁ itself survives (only its gift posting was destroyed)"
  end

  # --- #9 hardening: model backstops -------------------------------------

  test "a cross-entity JE₂ whose real leg is a BALANCE account is invalid (nominal-only)" do
    uuid = SecureRandom.uuid
    JournalEntry.create!(entry_date: Date.current, postings: [
      Posting.new(account: accounts(:personal_drawings), amount: 5_000, entry_type: :debit, cross_entity_link_id: uuid),
      Posting.new(account: accounts(:bank_gbp), amount: 5_000, entry_type: :credit)
    ])
    je2 = JournalEntry.new(entry_date: Date.current, postings: [
      Posting.new(account: accounts(:daughter_capital), amount: 5_000, entry_type: :credit, cross_entity_link_id: uuid),
      Posting.new(account: accounts(:daughter_bank), amount: 5_000, entry_type: :debit) # asset → not a nominal leg
    ])
    assert_not je2.valid?
    assert je2.errors[:base].any?, "the cross-entity real leg must be income/expense"
  end

  test "a cross-entity capital whose currency ≠ the linked bank's is invalid" do
    uuid = SecureRandom.uuid
    # JE₁ (entity 10): gift + a EUR bank
    JournalEntry.create!(entry_date: Date.current, postings: [
      Posting.new(account: accounts(:personal_drawings), amount: 5_000, entry_type: :debit, cross_entity_link_id: uuid),
      Posting.new(account: accounts(:bank_eur), amount: 5_000, entry_type: :credit)
    ])
    # JE₂ (entity 04): a GBP capital → GBP ≠ EUR
    je2 = JournalEntry.new(entry_date: Date.current, postings: [
      Posting.new(account: accounts(:daughter_capital), amount: 5_000, entry_type: :credit, cross_entity_link_id: uuid),
      Posting.new(account: accounts(:daughter_expenses), amount: 5_000, entry_type: :debit)
    ])
    capital = je2.postings.first
    assert_not capital.valid?
    assert capital.errors[:base].any?, "capital currency must match the bank currency"
  end

  # --- Integrity guard (step 2) -----------------------------------------

  test "a consistent link is valid on both sides" do
    assert @bridge1.valid?, @bridge1.errors.full_messages.join(", ")
    assert @bridge2.valid?, @bridge2.errors.full_messages.join(", ")
  end

  test "a non-mirrored amount is invalid" do
    @bridge1.amount = 20_000
    assert_not @bridge1.valid?
    assert @bridge1.errors[:base].any?
  end

  test "same entry type (not opposite) is invalid" do
    @bridge1.entry_type = @bridge2.entry_type
    assert_not @bridge1.valid?
    assert @bridge1.errors[:base].any?
  end

  test "both bridge postings in the same journal entry is invalid" do
    uuid = SecureRandom.uuid
    p1, p2 = @plain.postings.to_a
    p1.update_column(:cross_entity_link_id, uuid)
    p2.update_column(:cross_entity_link_id, uuid)
    assert_not p1.reload.valid?
  end

  test "a third posting sharing the link is invalid" do
    @bank1.update_column(:cross_entity_link_id, @link_id)
    assert_not @bridge1.reload.valid?
  end

  test "a link whose counterpart is not yet persisted does not block (atomic creation)" do
    fresh = Posting.new(account: accounts(:boss_drawings), amount: 5_000,
                             entry_type: :debit, cross_entity_link_id: SecureRandom.uuid,
                             journal_entry: @plain)
    assert fresh.valid?, fresh.errors.full_messages.join(", ")
  end
end
