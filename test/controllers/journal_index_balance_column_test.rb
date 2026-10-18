# frozen_string_literal: true

require "test_helper"

# The column used to show whichever balance account the database returned first,
# from an unordered pluck — so a transfer showed one end at random, and which
# end could change between page loads. 61 of Daniela's 168 entries are transfers.
class JournalIndexBalanceColumnTest < ActionDispatch::IntegrationTest
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    @entity = entities(:family_biz)
    @entity.update!(tax_schemes: [ "gb_vat" ])
    sign_in_as(admins(:two))
  end

  def index_body
    get journal_entries_path(locale: :en)
    assert_response :success
    response.body
  end

  test "an entry with nominals names its one balance account" do
    je = JournalEntry.new(entry_date: Date.new(2026, 5, 1), memo: "rent", posted: true)
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit,  amount: 10_000)
    je.postings.build(account: accounts(:bank_gbp),         entry_type: :credit, amount: 10_000)
    je.save!

    assert_match(/#{accounts(:bank_gbp).code} - #{Regexp.escape(accounts(:bank_gbp).name)}/, index_body)
  end

  # A transfer has no single balance account to name, and across three accounts
  # there is no direction the app could vouch for. So it lists the codes.
  test "a transfer lists both codes" do
    je = JournalEntry.new(entry_date: Date.new(2026, 5, 2), memo: "moving money", posted: true)
    je.postings.build(account: accounts(:bank_gbp),     entry_type: :credit, amount: 5_000)
    je.postings.build(account: accounts(:bank_gbp_two), entry_type: :debit,  amount: 5_000)
    je.save!

    codes = [ accounts(:bank_gbp).code, accounts(:bank_gbp_two).code ].sort
    assert_match(/#{codes.first}, #{codes.last}/, index_body,
                 "both ends of the transfer, in a stable order")
  end

  # The derived VAT leg lands on a control account, which IS a balance account.
  # Settled against a creditor on purpose: the input-VAT control (1xxxxx) sorts
  # BEFORE a payable (2xxxxx), so without excluding the leg the column would
  # name the VAT control instead of the real account. Against a bank it would
  # pass either way, which is how the first version of this test fooled me.
  test "a derived VAT leg is not mistaken for the entry's balance account" do
    code = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: Date.new(2026, 5, 3))
    je = JournalEntry.new(entry_date: Date.new(2026, 5, 3), memo: "on credit", posted: true)
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                      amount: 12_000, tax_code_id: code.id)
    je.derive_tax_legs
    je.postings.build(account: accounts(:accounts_payable), entry_type: :credit,
                      amount: 12_000, currency: "GBP")
    je.save!

    control = Account.active.vat_accounts.for_entity_codes([ "10" ]).find_by(vat_role: :input)
    payable = accounts(:accounts_payable)
    assert_operator control.code, :<, payable.code,
                    "the premise: the control account sorts first, so a bug would surface"

    body = index_body
    assert_match(/#{payable.code} - #{Regexp.escape(payable.name)}/, body)
    assert_no_match(/#{control.code} - /, body,
                    "the VAT control is not this entry's balance account")
  end
end
