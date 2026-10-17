# frozen_string_literal: true

require "test_helper"

# What the books must look like after a VAT entry. Not "derive_tax_legs built a
# posting" — the bank matching the statement, the P&L showing the net, and the
# control account holding exactly what is owed or reclaimable.
class JournalEntryVatTest < ActiveSupport::TestCase
  setup do
    TaxSchemeConfig.reload!
    TaxCategoryLoader.call(Rails.root.join("db/tax_categories/gb_vat_2026.yml"))
    entities(:family_biz).update!(tax_schemes: [ "gb_vat" ])
    @date     = Date.new(2026, 5, 1)
    @purchase = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: @date)
    @sale     = TaxCode.resolve(scheme: "gb_vat", key: "sale_standard",     on: @date)
    @reverse  = TaxCode.resolve(scheme: "gb_vat", key: "purchase_reverse_charge_services", on: @date)
  end

  # The bank form's own sequence: derive, then sum the rest into the bank leg.
  # If the order were wrong the bank leg would be the net and nothing would
  # balance, so every test here goes through it.
  def bank_entry(gross:, code:, account: accounts(:expenses_general), side: :debit,
                 date: @date, tax_amount: nil, bank: accounts(:bank_gbp))
    je = JournalEntry.new(entry_date: date, memo: "vat test")
    je.postings.build(account: account, entry_type: side, amount: gross,
                      tax_code_id: code&.id, tax_amount_display: tax_amount)
    je.derive_tax_legs
    balance = je.postings.reject(&:marked_for_destruction?)
                .sum { |p| p.debit? ? p.amount.to_i : -p.amount.to_i }
    je.postings.build(account: bank, entry_type: balance.positive? ? :credit : :debit,
                      amount: balance.abs, currency: bank.currency)
    je
  end

  # What the bank form does after derivation on an update.
  def rebalance_bank(je, bank: accounts(:bank_gbp))
    leg = je.postings.find { |p| p.account_id == bank.id }
    balance = je.postings.reject(&:marked_for_destruction?)
                .reject { |p| p.account_id == bank.id }
                .sum { |p| p.debit? ? p.amount.to_i : -p.amount.to_i }
    leg.assign_attributes(amount: balance.abs, entry_type: balance.positive? ? :credit : :debit)
  end

  def amount_on(je, account)
    posting = je.postings.reject(&:marked_for_destruction?).find { |p| p.account_id == account.id }
    posting && (posting.debit? ? posting.amount : -posting.amount)
  end

  def vat_account(direction)
    Account.active.vat_accounts.for_entity_codes([ "10" ])
           .find_by(tax_scheme: "gb_vat", vat_role: direction)
  end

  test "a purchase typed as gross leaves the bank at the gross and the P&L at the net" do
    je = bank_entry(gross: 12_000, code: @purchase)
    assert je.save, je.errors.full_messages.join("; ")

    assert_equal(-12_000, amount_on(je, accounts(:bank_gbp)), "the bank must match the statement")
    assert_equal 10_000,  amount_on(je, accounts(:expenses_general)), "the expense is the net"
    assert_equal 2_000,   amount_on(je, vat_account(:input)), "input VAT is reclaimable"
    assert_equal je.total_debits, je.total_credits
  end

  test "a sale works the same way, the other way up" do
    je = bank_entry(gross: 12_000, code: @sale, account: accounts(:income_sales), side: :credit)
    assert je.save, je.errors.full_messages.join("; ")

    assert_equal 12_000,   amount_on(je, accounts(:bank_gbp)), "money in, at the gross"
    assert_equal(-10_000,  amount_on(je, accounts(:income_sales)))
    assert_equal(-2_000,   amount_on(je, vat_account(:output)), "output VAT is owed")
  end

  # The gross is the invariant. Whatever the VAT figure does, net + VAT = gross,
  # so the bank leg never stops matching the bank.
  test "net plus VAT equals the gross at every rate, including the awkward ones" do
    [ 12_000, 10_000, 1, 3, 9, 99_999 ].each do |gross|
      je = bank_entry(gross: gross, code: @purchase)
      net = amount_on(je, accounts(:expenses_general))
      vat = je.postings.reject(&:marked_for_destruction?).select(&:tax_leg?).sum { |p| p.amount.to_i }
      assert_equal gross, net + vat, "gross #{gross} split into #{net} + #{vat}"
    end
  end

  test "20 per cent of a gross 100.00 is 16.67, not 20.00" do
    je = bank_entry(gross: 10_000, code: @purchase)
    assert_equal 1_667, je.postings.find(&:tax_leg?).amount
    assert_equal 8_333, amount_on(je, accounts(:expenses_general))
  end

  # An invoice that rounded differently from us. The user's figure wins and the
  # NET moves to absorb it — never the gross.
  test "an edited VAT figure moves the net, not the bank" do
    je = bank_entry(gross: 11_899, code: @purchase, tax_amount: "18.99")
    assert je.save, je.errors.full_messages.join("; ")

    assert_equal(-11_899, amount_on(je, accounts(:bank_gbp)))
    assert_equal 1_899,   amount_on(je, vat_account(:input))
    assert_equal 10_000,  amount_on(je, accounts(:expenses_general))
  end

  # The supplier charged nothing; we owe the VAT and reclaim it in one breath.
  # The bank must not move by a penny more than the invoice.
  test "reverse charge leaves the bank alone and fills both control accounts" do
    je = bank_entry(gross: 10_000, code: @reverse)
    assert je.save, je.errors.full_messages.join("; ")

    assert_equal(-10_000, amount_on(je, accounts(:bank_gbp)), "the invoice carried no VAT")
    assert_equal 10_000,  amount_on(je, accounts(:expenses_general))
    assert_equal 2_000,   amount_on(je, vat_account(:input))
    assert_equal(-2_000,  amount_on(je, vat_account(:output)))
    assert_equal je.total_debits, je.total_credits
  end

  test "the control accounts are created once, not once per entry" do
    bank_entry(gross: 12_000, code: @purchase).save!
    assert_difference -> { Account.vat_accounts.count }, 0 do
      bank_entry(gross: 6_000, code: @purchase).save!
    end
  end

  test "a created control account is in the scheme's currency and says what it is" do
    bank_entry(gross: 12_000, code: @purchase).save!
    account = vat_account(:input)

    assert_equal "GBP", account.currency, "the authority is paid in one currency"
    assert account.asset?, "input VAT is money the authority owes back"
    assert_equal "gb_vat", account.tax_scheme
    assert_not account.locked?, "the user must be able to rename it"
  end

  # The point of versioning the codes by date.
  test "a rate that had not started yet cannot be used" do
    je = bank_entry(gross: 12_000, code: @purchase, date: Date.new(2009, 6, 1))
    assert_not je.save
    assert je.errors.full_messages.any? { |m| m.include?("tax_code_date") || m.match?(/VAT|code/i) },
           je.errors.full_messages.join("; ")
  end

  test "a code from a scheme the business does not file is refused" do
    entities(:family_biz).update!(tax_schemes: [])
    je = bank_entry(gross: 12_000, code: @purchase)
    assert_not je.save
  end

  test "a code on an entry in another currency is refused" do
    je = bank_entry(gross: 12_000, code: @purchase, bank: accounts(:bank_eur))
    assert_not je.save, "GBP VAT cannot be reclaimed through a EUR account"
  end

  test "a VAT code on a balance-sheet row is refused" do
    je = bank_entry(gross: 12_000, code: @purchase, account: accounts(:accounts_payable))
    assert_not je.save
  end

  # The narrow relaxation, stated as the thing it protects: a derived leg is
  # exempt, a hand-typed one is not.
  test "a VAT posting typed by hand next to nominals is still refused" do
    je = bank_entry(gross: 12_000, code: @purchase)
    je.save!
    control = vat_account(:input)

    hand = JournalEntry.new(entry_date: @date, memo: "typed by hand")
    hand.postings.build(account: accounts(:expenses_general), entry_type: :debit, amount: 10_000)
    hand.postings.build(account: control, entry_type: :debit, amount: 2_000, currency: "GBP")
    hand.postings.build(account: accounts(:bank_gbp), entry_type: :credit, amount: 12_000, currency: "GBP")

    assert_not hand.save, "a VAT leg with no code behind it would never reach the return"
  end

  test "deleting the net row takes its VAT leg with it" do
    je = bank_entry(gross: 12_000, code: @purchase)
    je.save!
    assert_equal 3, je.postings.count

    net = je.postings.reload.find { |p| p.account_id == accounts(:expenses_general).id }
    net.destroy

    assert_equal 1, je.postings.reload.count, "the leg goes with the row it was derived from"
  end

  test "clearing the code removes the leg and gives the row its gross back" do
    je = bank_entry(gross: 12_000, code: @purchase)
    je.save!

    # What the form sends: the amount field still holds the gross, the code
    # select is now blank.
    je.reload
    net = je.postings.find { |p| p.account_id == accounts(:expenses_general).id }
    net.assign_attributes(amount: 12_000, tax_code_id: nil)
    je.derive_tax_legs
    rebalance_bank(je)

    assert je.postings.select(&:tax_leg?).all?(&:marked_for_destruction?)
    assert je.save, je.errors.full_messages.join("; ")
    assert_equal 2, je.postings.reload.count
    assert_equal 12_000, amount_on(je, accounts(:expenses_general))
    assert_equal(-12_000, amount_on(je, accounts(:bank_gbp)))
  end

  # The ordinary correction: it was reduced rate all along, not standard. What
  # the user typed — the gross — must not move, because the bank statement has
  # not changed. Everything derived from it does.
  test "changing the code to another rate re-derives the VAT and leaves the gross alone" do
    je = bank_entry(gross: 12_000, code: @purchase)
    je.save!
    leg_id = je.postings.find(&:tax_leg?).id
    reduced = TaxCode.resolve(scheme: "gb_vat", key: "purchase_reduced", on: @date)

    je.reload
    net = je.postings.find { |p| p.account_id == accounts(:expenses_general).id }
    net.assign_attributes(amount: 12_000, tax_code_id: reduced.id)
    je.derive_tax_legs
    rebalance_bank(je)
    assert je.save, je.errors.full_messages.join("; ")

    je.reload
    assert_equal(-12_000, amount_on(je, accounts(:bank_gbp)), "the statement has not changed")
    # 120.00 at 5% is 5.71 of VAT (5.714 half-up), net 114.29.
    assert_equal 571,    amount_on(je, vat_account(:input))
    assert_equal 11_429, amount_on(je, accounts(:expenses_general))
    assert_equal leg_id, je.postings.find(&:tax_leg?).id,
                 "the same leg is corrected, not deleted and replaced"
  end

  # A rate that did not exist yet cannot be applied retrospectively, whichever
  # way round the user comes at it: the code is not offered on the form, and a
  # forced one is refused.
  test "a rate introduced later cannot be put on an older entry" do
    old_entry = bank_entry(gross: 12_000, code: @purchase, date: Date.new(2009, 6, 1))
    assert_not old_entry.save, "20% did not exist in 2009"

    offered = TaxCode.options_for(schemes: [ "gb_vat" ], on: Date.new(2009, 6, 1))
    assert_empty offered.select { |label, _id, _data| label.include?("20%") },
                 "and the form does not offer it either"
  end

  # The rate in force on a date is the one that resolves, which is what makes
  # moving an entry across a rate change re-derive correctly.
  test "an older rate row applies to an older date under the same code key" do
    TaxCode.create!(country_code: "gb", scheme: "gb_vat", key: "purchase_standard",
                    label: "Purchase, standard rate", rate_bps: 1750, direction: "input",
                    valid_from: Date.new(2008, 12, 1), valid_to: Date.new(2011, 1, 3),
                    net_category_key: "total_purchases_ex_vat",
                    tax_category_key: "vat_reclaimed", position: 110)

    older = TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard", on: Date.new(2010, 6, 1))
    assert_equal 1750, older.rate_bps
    assert_equal 2000, TaxCode.resolve(scheme: "gb_vat", key: "purchase_standard",
                                       on: @date).rate_bps
  end

  # Book it, save it, then come back and split it — the sequence a real user
  # follows when they realise afterwards that the phone bill was partly private.
  # The existing VAT leg has to be CORRECTED, not left at the old figure, and
  # the bank must not move.
  test "splitting a saved VAT entry re-derives the VAT and leaves the bank alone" do
    je = bank_entry(gross: 12_000, code: @purchase)
    je.save!
    leg_id = je.postings.find(&:tax_leg?).id

    # What the form submits after the split modal: the business row cut to the
    # 70% gross with its own VAT, plus a new private row for the rest.
    je.reload
    business = je.postings.find { |p| p.account_id == accounts(:expenses_general).id }
    pair = SecureRandom.uuid
    business.assign_attributes(amount: 8_400, tax_amount_display: "14.00",
                               deduction_pair_id: pair, deduction_percentage: 70)
    je.postings.build(account: accounts(:personal_drawings), entry_type: :debit,
                      amount: 3_600, deduction_pair_id: pair, deduction_percentage: 30)
    je.derive_tax_legs
    rebalance_bank(je)
    assert je.save, je.errors.full_messages.join("; ")

    je.reload
    assert_equal(-12_000, amount_on(je, accounts(:bank_gbp)), "the statement has not changed")
    assert_equal 7_000,  amount_on(je, accounts(:expenses_general)), "70% of the net"
    assert_equal 1_400,  amount_on(je, vat_account(:input)), "70% of the VAT, reclaimable"
    assert_equal 3_600,  amount_on(je, accounts(:personal_drawings)),
                 "the private share carries its own unreclaimed VAT"
    assert_equal leg_id, je.postings.find(&:tax_leg?).id, "the same leg, corrected"
    assert_equal 1, je.postings.count(&:tax_leg?), "the private row gets none"
  end

  test "a VAT code on the private row of a split is refused" do
    je = bank_entry(gross: 8_400, code: @purchase)
    je.postings.build(account: accounts(:personal_drawings), entry_type: :debit,
                      amount: 3_600, tax_code_id: @purchase.id)

    assert_not je.save, "VAT on private use is country-specific and out of scope"
  end

  # A gift in the entry does not make the donor's own purchases untaxable. The
  # 601 bridge is money leaving for someone else's business; the expense row
  # beside it is the donor's own, and so is its VAT.
  test "a donor can still reclaim VAT on their own row in an entry holding a gift" do
    link = SecureRandom.uuid
    je = JournalEntry.new(entry_date: @date, memo: "supplies, and a gift")
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit,
                      amount: 12_000, tax_code_id: @purchase.id)
    je.postings.build(account: accounts(:personal_drawings), entry_type: :debit,
                      amount: 5_000, cross_entity_link_id: link)
    je.derive_tax_legs
    balance = je.postings.reject(&:marked_for_destruction?)
                .sum { |p| p.debit? ? p.amount.to_i : -p.amount.to_i }
    je.postings.build(account: accounts(:bank_gbp), entry_type: :credit,
                      amount: balance.abs, currency: "GBP")

    assert je.save, je.errors.full_messages.join("; ")
    assert_equal 2_000,  amount_on(je, vat_account(:input))
    assert_equal 10_000, amount_on(je, accounts(:expenses_general))
    assert_equal(-17_000, amount_on(je, accounts(:bank_gbp)), "gross plus the gift")
  end

  # The receiving side is where VAT has to stop. The receiver did not buy
  # anything — a gift arrived — and whose VAT it is follows the invoice, which
  # this app does not record.
  test "the receiving side of a cross-entity gift cannot carry a VAT code" do
    entities(:daughter).update!(tax_schemes: [ "gb_vat" ])
    link = SecureRandom.uuid

    je2 = JournalEntry.new(entry_date: @date, memo: "gift received")
    je2.postings.build(account: accounts(:daughter_capital), entry_type: :credit,
                       amount: 10_000, cross_entity_link_id: link)
    je2.postings.build(account: accounts(:daughter_expenses), entry_type: :debit,
                       amount: 10_000, tax_code_id: @purchase.id)
    je2.derive_tax_legs

    assert_not je2.save, "VAT on a gift is not the receiver's to reclaim"
  end

  # The live bug, 2026-10-06: "Sale, reduced rate" picked on an Electricity
  # expense derived its leg into the OUTPUT VAT account, and the return
  # reported £1.99 of tax OWED on money that had been spent. Nothing on screen
  # looked wrong.
  test "a sale code on an expense row is refused" do
    je = bank_entry(gross: 3_984, code: TaxCode.resolve(scheme: "gb_vat",
                                                        key: "sale_reduced", on: @date))
    assert_not je.save, "you do not charge VAT on electricity you buy"
  end

  test "a purchase code on an income row is refused" do
    je = bank_entry(gross: 12_000, code: @purchase,
                    account: accounts(:income_sales), side: :credit)
    assert_not je.save
  end

  # The dropdown that made the mistake possible: a flat list where the two
  # "reduced rate" entries were six rows apart.
  test "the codes are grouped by direction, so the two reduced rates cannot be confused" do
    groups = TaxCode.options_for(schemes: [ "gb_vat" ], on: @date)

    assert_equal 2, groups.size
    # The labels dropped "Purchase," and "Sale," once the groups said it, so
    # "Reduced rate (5%)" now reads the same in both — which is exactly why the
    # grouping has to be there.
    labels = groups.map { |name, options| [ name, options.map(&:first) ] }.to_h
    labels.each_value { |options| assert_includes options, "Reduced rate (5%)" }
    assert_equal 2, labels.values.count { |o| o.include?("Reduced rate (5%)") }
    groups.each do |_name, options|
      directions = options.map { |_l, _id, data| data[:data][:direction] }.uniq
      assert_equal 1, directions.size, "a group holds one direction only"
    end
  end

  # Deriving twice over the same object must not take the VAT off twice — the
  # bank-entry controller re-renders and re-derives on a failed save.
  test "deriving twice does not split the amount twice" do
    je = bank_entry(gross: 12_000, code: @purchase)
    je.derive_tax_legs
    je.derive_tax_legs

    assert_equal 10_000, amount_on(je, accounts(:expenses_general))
    assert_equal 1, je.postings.count(&:tax_leg?)
  end

  test "an entry with no codes is untouched and costs no queries" do
    je = JournalEntry.new(entry_date: @date, memo: "plain")
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit, amount: 10_000)
    je.postings.build(account: accounts(:bank_gbp), entry_type: :credit, amount: 10_000, currency: "GBP")

    assert_no_queries { je.derive_tax_legs if je.tax_coded? }
    assert je.save, je.errors.full_messages.join("; ")
    assert_equal 10_000, amount_on(je, accounts(:expenses_general))
  end

  # German EÜR keeps VAT in the P&L: a cash-basis return has no balance sheet to
  # put a control account on, and its catalogue already carries vereinnahmte and
  # gezahlte Umsatzsteuer as income and expense lines. The scheme header says so
  # (vat_accounts: nominal), and nothing else about VAT changes.
  #
  # No shipped catalogue declares it yet, so the scheme's answer is stubbed —
  # that one header value is the whole input that decides the account's type.
  def with_nominal_vat_accounts
    TaxSchemeConfig.stub(:vat_accounts_nominal?, true) do
      # The type is decided when the scheme is SUBSCRIBED, so the pair setup
      # made under the balance-sheet rule has to go and come back under this one.
      entity = entities(:family_biz)
      entity.update!(tax_schemes: [])
      entity.update!(tax_schemes: [ "gb_vat" ])
      yield
    end
  end

  test "a scheme that keeps VAT in the P&L gets an expense account, not an asset" do
    je = with_nominal_vat_accounts { bank_entry(gross: 12_000, code: @purchase).tap(&:save!) }
    control = Account.vat_accounts.for_entity_codes([ "10" ]).find_by(vat_role: :input)

    assert control.expense?, "input VAT is a cost under EÜR, not a receivable"
    assert_nil control.currency, "a nominal account carries none — it borrows the entry's"
    assert_equal "gb_vat", control.tax_scheme
    assert_equal(-12_000, amount_on(je, accounts(:bank_gbp)), "the bank still matches the statement")
    assert_equal 10_000, amount_on(je, accounts(:expenses_general))
    assert_equal 2_000,  amount_on(je, control)
  end

  # The gross reaches the P&L across TWO lines instead of one, which is what a
  # cash-basis return wants: the expense net, the VAT beside it.
  test "under EUER the whole gross is in the P&L, split over two lines" do
    je = with_nominal_vat_accounts { bank_entry(gross: 12_000, code: @purchase).tap(&:save!) }
    control = Account.vat_accounts.for_entity_codes([ "10" ]).find_by(vat_role: :input)

    # This entry's own lines only — the fixtures already put money on the
    # expense account, and the claim is about what THIS purchase did.
    assert_equal 12_000, amount_on(je, accounts(:expenses_general)) + amount_on(je, control)
  end

  # Year-end closes nominal accounts. A balance-sheet VAT account must survive
  # it (what is owed does not stop being owed); an EÜR one must be closed with
  # the rest of the P&L. Both follow from the account's TYPE, which is the whole
  # reason the type is the scheme's decision and not an afterthought.
  test "a balance-sheet VAT account is not something year-end closes" do
    bank_entry(gross: 12_000, code: @purchase).save!
    control = Account.vat_accounts.for_entity_codes([ "10" ]).find_by(vat_role: :input)

    assert control.balance_account?, "GB VAT is a control account on the balance sheet"
    assert_not control.income?, "and so is never swept into retained earnings"
    assert_not control.expense?
  end

  # A VAT control account is an ordinary account — rename it, give it a parent,
  # slot it into your own numbering. But its TYPE digit is the scheme's
  # decision, not the user's, and its entity digits are no more theirs than any
  # other account's.
  test "a VAT account's type and entity digits cannot be renumbered" do
    bank_entry(gross: 12_000, code: @purchase).save!
    control = vat_account(:input)

    control.code = control.code.sub(/\A1/, "5")
    assert_not control.save, "1xx to 5xx would move what HMRC owes into the P&L"

    control.reload.code = "10#{"4"}#{control.code[3..]}"
    assert_not control.save, "nor into another business's range"
  end

  test "a VAT account can still be renamed and renumbered within its own range" do
    bank_entry(gross: 12_000, code: @purchase).save!
    control = vat_account(:input)
    prefix  = control.code.first(3)

    control.assign_attributes(name: "Input VAT control", code: "#{prefix}450")
    assert control.save, control.errors.full_messages.join("; ")
    assert_equal "Input VAT control", control.reload.name
    assert_equal "#{prefix}450", control.code
  end

  # The window the ordinary rule misses: subscribing to the scheme creates the
  # pair, so a control account normally has no postings for a while.
  test "the digits are locked even before the account has any postings" do
    fresh = vat_account(:input)
    assert_equal 0, fresh.postings.count

    fresh.code = fresh.code.sub(/\A1/, "5")
    assert_not fresh.save, "no postings is exactly when this would go unnoticed"
  end

  # The role is how the app RECOGNISES a VAT account. Deactivating used to strip
  # it, which left an account still holding VAT that nothing knew was a VAT
  # account — so a duplicate got created, its old postings became orphans, and
  # the one-balance-account rule refused the entry they were in. Found in the
  # real books, 2026-10-07.
  test "deactivating a VAT account keeps its role" do
    bank_entry(gross: 12_000, code: @purchase).save!
    control = vat_account(:input)

    # Its balance has to go first — not_deactivated_with_a_balance refuses
    # otherwise, which is the protection that actually matters.
    control.postings.each { |p| p.journal_entry.destroy }
    control.reload.update!(active: false)

    assert_equal "input", control.reload.vat_role,
                 "a dormant VAT account is still a VAT account"
  end

  test "a dormant VAT account is skipped for new entries, and a live one is made" do
    bank_entry(gross: 12_000, code: @purchase).save!
    old = vat_account(:input)
    old.postings.each { |p| p.journal_entry.destroy }
    old.reload.update!(active: false)

    bank_entry(gross: 6_000, code: @purchase).save!
    fresh = vat_account(:input)

    assert fresh, "a live account is resolved or created"
    assert_not_equal old.id, fresh.id
    assert_equal "input", old.reload.vat_role, "and the dormant one is untouched"
  end

  # The one-balance-account rule only bites where the control account is ON the
  # balance sheet. Under a nominal scheme it is an income or expense account, so
  # the rule never sees it and a hand-typed VAT posting is NOT refused — the
  # return's unassigned figure is the only thing that catches it. Documented in
  # concepts.md; asserted here so the prose cannot drift from the code.
  test "under a nominal scheme a hand-typed VAT posting saves but is reported" do
    control = with_nominal_vat_accounts do
      bank_entry(gross: 12_000, code: @purchase).save!
      vat_account(:input)
    end
    assert control.expense?, "a nominal scheme's input VAT is an expense"

    hand = JournalEntry.new(entry_date: @date, memo: "typed by hand", posted: true)
    hand.postings.build(account: accounts(:expenses_general), entry_type: :debit, amount: 10_000)
    hand.postings.build(account: control, entry_type: :debit, amount: 500)
    hand.postings.build(account: accounts(:bank_gbp), entry_type: :credit,
                        amount: 10_500, currency: "GBP")

    assert hand.save, "nothing refuses it: #{hand.errors.full_messages.join('; ')}"

    result = Reports::VatReturn.new(entity: entities(:family_biz), scheme: "gb_vat",
                                    from: @date.beginning_of_month,
                                    to: @date.end_of_month).call
    assert_equal(-500, result[:unassigned], "the return is what says so")
  end

  # The shape the old rule exists to refuse, and still does: a loan repayment
  # split into principal and interest holds two balance accounts the user typed.
  test "the loan-repayment shape is still refused" do
    je = JournalEntry.new(entry_date: @date, memo: "loan repayment")
    je.postings.build(account: accounts(:expenses_general), entry_type: :debit, amount: 1_000)
    je.postings.build(account: accounts(:accounts_payable), entry_type: :debit, amount: 9_000, currency: "GBP")
    je.postings.build(account: accounts(:bank_gbp), entry_type: :credit, amount: 10_000, currency: "GBP")

    assert_not je.save
  end
end
