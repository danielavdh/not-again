# frozen_string_literal: true
require "test_helper"

class Archives::BooksCsvTest < ActiveSupport::TestCase
  # Fixtures: entity 10 (:family_biz) is in g1, and entity 01 (:personal) is in
  # g1 too. Current-year postings live on entity 10's accounts.
  def scope_of(entity) = Archives::Storage.scope_key_for(entity.reload)

  test "lists every posted posting for the scope, debit and credit split, closing entries included" do
    entity = entities(:family_biz)
    backdate_family_membership!(entity)
    csv = Archives::BooksCsv.new(scope_key: scope_of(entity), year: Date.current.year).generate
    rows = CSV.parse(csv, col_sep: ",", headers: true)

    assert_equal %w[EntryID Date Entity AccountCode AccountName DebitMinor CreditMinor Currency Memo JournalReference], rows.headers

    bank_debit = rows.find { |r| r["AccountCode"] == accounts(:bank_gbp).code && r["DebitMinor"] == "10000" }
    assert bank_debit, "the posted deposit's debit leg should appear, got: #{rows.map(&:to_h)}"
    assert_equal "GBP", bank_debit["Currency"]
    assert_equal "10", bank_debit["Entity"]

    income_credit = rows.find { |r| r["AccountCode"] == accounts(:income_sales).code && r["CreditMinor"] == "10000" }
    assert income_credit, "the posted deposit's credit leg should appear"
    # income_sales is nominal — its OWN currency column is null; this must come
    # from the bank leg of the same journal entry, not be blank.
    assert_equal "GBP", income_credit["Currency"]
  end

  # A10. The archive is written both by an admin clicking close and by
  # Archives::SweepJob/FlushJob, which set no locale at all. If the shape
  # followed the locale, one folder would hold two incompatible formats and the
  # difference would record who generated the file, not anything about the
  # books.
  test "the same scope and year produce a byte-identical file in any locale or number format" do
    entity = entities(:family_biz)
    backdate_family_membership!(entity)
    scope = scope_of(entity)

    english = I18n.with_locale(:en) do
      Current.number_format = "uk"
      Archives::BooksCsv.new(scope_key: scope, year: Date.current.year).generate
    end

    german = I18n.with_locale(:de) do
      Current.number_format = "de"
      Archives::BooksCsv.new(scope_key: scope, year: Date.current.year).generate
    end

    no_format = begin
      Current.number_format = nil
      Archives::BooksCsv.new(scope_key: scope, year: Date.current.year).generate
    end

    assert_equal english, german,
      "a German admin's archive differs from an English admin's for the same books"
    assert_equal english, no_format,
      "a background job's archive differs from an admin's for the same books"
  ensure
    Current.number_format = nil
  end

  # A "." that a comma-decimal spreadsheet reads as a thousands separator turns
  # 95.00 into 9500 as a NUMBER, so it sums and nothing looks wrong. An integer
  # has nothing to misread, and it is the value actually stored.
  test "amounts are the stored integer, with no decimal separator to misread" do
    entity = entities(:family_biz)
    backdate_family_membership!(entity)
    csv = Archives::BooksCsv.new(scope_key: scope_of(entity), year: Date.current.year).generate
    rows = CSV.parse(csv, col_sep: ",", headers: true)

    amounts = rows.flat_map { |r| [ r["DebitMinor"], r["CreditMinor"] ] }.compact.reject(&:empty?)
    assert amounts.any?, "no amounts in the archive to check"
    amounts.each do |a|
      assert_match(/\A-?\d+\z/, a, "#{a.inspect} is not a bare integer")
    end

    posting = postings(:deposit_bank)
    assert_includes amounts, posting.amount.to_s,
      "the archive must carry the stored amount in minor units, undivided"
  end

  test "a draft (unposted) entry is excluded" do
    entity = entities(:family_biz)
    backdate_family_membership!(entity)
    je = journal_entries(:draft_entry)
    csv = Archives::BooksCsv.new(scope_key: scope_of(entity), year: je.entry_date.year).generate

    assert_not_includes csv, je.memo
  end

  test "postings from a scope's member are limited to the days it was in that scope" do
    group = EntityGroup.create!(name: "Windowed")
    e = travel_to(Date.new(2020, 1, 1)) { Entity.create!(code: "73", name: "Joiner") }
    bank = Account.create!(code: "173001", name: "Bank", account_type: :asset, currency: "GBP")
    inc  = Account.create!(code: "473001", name: "Sales", account_type: :income)

    post = ->(date) {
      je = JournalEntry.new(entry_date: date, memo: "e73 #{date}")
      je.postings.build(account: bank, amount: 1000, entry_type: :debit, currency: "GBP")
      je.postings.build(account: inc,  amount: 1000, entry_type: :credit)
      je.posted = true
      je.save!
    }
    travel_to(Date.new(2025, 6, 15)) { post.call(Date.new(2025, 2, 1)) } # pre-join
    travel_to(Date.new(2025, 6, 15)) { e.update!(entity_group: group) }  # joins mid-year
    post.call(Date.new(2025, 9, 1))                                       # in-family

    family = Archives::BooksCsv.new(scope_key: "g#{group.id}", year: 2025).generate
    solo   = Archives::BooksCsv.new(scope_key: "73", year: 2025).generate

    assert_includes    family, "e73 2025-09-01", "in-family entry belongs to the family archive"
    assert_not_includes family, "e73 2025-02-01", "pre-join entry must not be in the family archive"
    assert_includes    solo,   "e73 2025-02-01", "pre-join entry belongs to the entity's own archive"
    assert_not_includes solo,   "e73 2025-09-01", "in-family entry must not be duplicated into the solo archive"
  end
end
