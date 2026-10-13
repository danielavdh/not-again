# frozen_string_literal: true
require "test_helper"

# An accountant export is an EXTRA file alongside the two everyone gets — the
# transactions listing and, for a tax report, the tax-category CSV. Blank means
# "the standard ones are fine", not "no export".
class AccountantExportsTest < ActiveSupport::TestCase
  Base = AccountantExports::Base

  test "the registry lists every declared format and nothing else" do
    assert_equal Base::FORMATS.sort, Base.all.map(&:slug).sort
  end

  test "an unknown or blank slug resolves to nothing rather than raising" do
    assert_nil Base.for(nil)
    assert_nil Base.for("")
    assert_nil Base.for("spaghetti")
  end

  # The formats are siblings of Base, not nested inside it: const_get on Base
  # itself silently returned nothing, so the dropdown was empty and the job
  # attached no file.
  test "a declared slug resolves to its class" do
    assert_equal AccountantExports::Datev, Base.for("datev")
  end

  test "every format answers the whole interface" do
    Base.all.each do |format|
      assert format.label.present?,    "#{format} needs a label"
      assert format.filename.present?, "#{format} needs a filename"
      assert format.instance_methods(false).include?(:generate) ||
             format.superclass.instance_methods(false).include?(:generate),
             "#{format} needs #generate"
    end
  end

  # ── DATEV ──────────────────────────────────────────────────────────────────

  setup do
    @entity = entities(:family_biz)
    code    = @entity.code
    @sales  = Account.create!(code: "4#{code}970", name: "Sales", account_type: :income)
    @bank   = Account.create!(code: "1#{code}970", name: "Bank", account_type: :asset,
                                   currency: "EUR")

    @je = JournalEntry.new(entry_date: Date.new(2026, 3, 14), posted: true, memo: "A sale")
    @je.postings.build(account: @bank,  entry_type: :debit,  amount: 12_345, currency: "EUR")
    @je.postings.build(account: @sales, entry_type: :credit, amount: 12_345, currency: "EUR")
    @je.save!
  end

  def datev_csv
    AccountantExports::Datev.new(
      postings:   Posting.where(account_id: @sales.id).includes(journal_entry: { postings: :account }),
      entity:     @entity,
      start_date: Date.new(2026, 1, 1),
      end_date:   Date.new(2026, 12, 31)
    ).generate
  end

  test "DATEV writes its own conventions, not ours" do
    rows = CSV.parse(datev_csv, col_sep: ";")

    assert_equal "EXTF", rows[0][0]
    assert_equal "Buchungsstapel", rows[0][3]
    assert_equal "Umsatz", rows[1][0]

    entry = rows[2]
    assert_equal "123,45", entry[0], "comma decimal mark, not a point"
    assert_equal "H",      entry[1], "credit is H (Haben), not a minus sign"
    assert_equal @sales.code,  entry[6]
    assert_equal @bank.code,   entry[7], "the balance account faces it"
    assert_equal "1403",   entry[9], "Belegdatum is DDMM — the year is in the header"
  end

  # DATEV books one line per pair, so a nominal posting with no balance account
  # facing it cannot be expressed. Skipped, never guessed at.
  test "a posting with no balance-sheet counterpart is left out" do
    other = Account.create!(code: "5#{@entity.code}970", name: "Other", account_type: :expense)
    je = JournalEntry.new(entry_date: Date.new(2026, 4, 1), posted: true, memo: "nominal only")
    je.postings.build(account: @sales, entry_type: :credit, amount: 500)
    je.postings.build(account: other,  entry_type: :debit,  amount: 500)
    je.save!(validate: false)

    rows = CSV.parse(datev_csv, col_sep: ";")
    assert_equal 3, rows.size, "header, column names, and only the bankable entry"
  end

  # DATEV works the VAT out itself from the BU-Schlüssel, so it wants the GROSS
  # and the key. Sending it our net would make it deduct the tax a second time,
  # and the accountant's books would be short by it.
  test "a VAT entry goes to DATEV as the gross with its BU-Schlüssel" do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @entity.update!(tax_schemes: [ "gb_vat" ])
    # DATEV is a German format, but the VAT mechanism is the same whichever
    # catalogue supplies the code; gb_vat is the one that ships.
    code = TaxCode.resolve(scheme: "gb_vat", key: "sale_standard", on: Date.new(2026, 3, 14))
    code.update!(datev_bu: "3")
    gbp_bank = Account.create!(code: "1#{@entity.code}971", name: "GBP Bank",
                               account_type: :asset, currency: "GBP")

    je = JournalEntry.new(entry_date: Date.new(2026, 3, 14), posted: true, memo: "A VAT sale")
    je.postings.build(account: @sales, entry_type: :credit, amount: 12_000, tax_code_id: code.id)
    je.derive_tax_legs
    je.postings.build(account: gbp_bank, entry_type: :debit, amount: 12_000, currency: "GBP")
    je.save!

    rows = CSV.parse(datev_csv, col_sep: ";")
    vat_row = rows.find { |r| r[13] == "A VAT sale" }

    assert vat_row, "the sale should be exported, got #{rows.map { |r| r[13] }.inspect}"
    assert_equal "120,00", vat_row[0], "the gross, not the 100.00 net we store"
    assert_equal "3",      vat_row[8], "the BU-Schlüssel DATEV computes the VAT from"
    assert_equal gbp_bank.code, vat_row[7], "the BANK faces it, never the VAT control account"
    assert_equal 1, rows.count { |r| r[13] == "A VAT sale" }, "no row of its own for the VAT leg"
  end
end
