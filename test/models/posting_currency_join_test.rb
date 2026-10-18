# frozen_string_literal: true

require "test_helper"

# A nominal posting has no currency of its own — it takes the currency of the
# balance-sheet row in the same entry. A derived VAT leg sits on a control
# account, which IS a balance-sheet row, so it matched too; with LIMIT 1 and no
# ORDER BY, which of the two answered was undefined.
#
# That matters beyond VAT: this join is how every nominal posting gets its
# currency, in the ledger, the trial balance and every report built on them. A
# leg in a scheme's own currency could hand a euro entry's expenses a sterling
# one.
class PostingCurrencyJoinTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    entities(:family_biz).update!(tax_schemes: [ "gb_vat" ])
    @date = Date.new(2026, 5, 15)
  end

  # Written against the state the fix has to survive, which the validations do
  # not currently allow a user to reach: the leg is forced to a currency the
  # entry is not in, as a scheme-currency leg would be.
  test "an expense takes its currency from the bank, never from a VAT leg" do
    code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: @date)
    je = JournalEntry.new(entry_date: @date, memo: "phone", posted: true)
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                      amount: 12_000, tax_code_id: code.id)
    je.derive_tax_legs
    balance = je.postings.reject(&:marked_for_destruction?)
                .sum { |p| p.debit? ? p.amount.to_i : -p.amount.to_i }
    je.postings.build(account: accounts(:bank_gbp), entry_type: :credit,
                      amount: balance.abs, currency: "GBP")
    je.save!

    # Moved to the euro account afterwards, because the currency guards do not
    # yet allow an entry to be built this way. The row state is what matters:
    # a euro bank, and a VAT leg in the scheme's own currency beside it.
    bank = je.postings.find { |p| p.account_id == accounts(:bank_gbp).id }
    bank.update_columns(account_id: accounts(:bank_eur).id, currency: "EUR")

    expense = je.postings.find { |p| p.account_id == accounts(:expenses_general).id }
    found = Posting.where(id: expense.id)
                   .joins(Posting.currency_join_sql)
                   .pick(Arel.sql(Posting.effective_currency_sql))

    assert_equal "EUR", found,
      "the expense was paid out of a euro account; the VAT leg's currency is not the entry's"
  end
end
