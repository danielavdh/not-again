# The public demo: one entity, nine months of books, and a read-only account
# that /demo signs strangers in as.
#
# It exists because the landing page makes three claims about currency — get
# paid in złoty, pay with a euro card, read the report in pound sterling — and a
# screenshot cannot prove any of them. These books can: the złoty income is
# booked in złoty because the account is in złoty, the card is in euros, and
# only the report converts.
#
# NOTHING IS SEEDED BY DEFAULT. A fresh clone has no demo admin, so /demo offers
# no way in and the landing page does not show the button. The door opens when
# somebody deliberately runs this, and closes again with demo:destroy.
namespace :demo do
  ENTITY_CODE = ENV.fetch("DEMO_ENTITY_CODE", "99")
  USERNAME    = ENV.fetch("DEMO_USERNAME", "demo")
  PRO_USERNAME    = "#{USERNAME}-pro"
  UPLOAD_USERNAME = "#{USERNAME}-receipts"

  desc "Create the demo books and the read-only account /demo uses"
  task seed: :environment do
    if Entity.exists?(code: ENTITY_CODE)
      abort <<~MSG
        Entity #{ENTITY_CODE} already exists, so this would be seeding on top of
        real books. Either it is already seeded — in which case `demo:destroy`
        first — or #{ENTITY_CODE} is yours, and you want:

            DEMO_ENTITY_CODE=98 bin/rails demo:seed
      MSG
    end

    if Admin.exists?(username: [ USERNAME, PRO_USERNAME, UPLOAD_USERNAME ])
      abort "An admin called #{USERNAME.inspect} already exists. Pass DEMO_USERNAME=… or remove it."
    end

    ActiveRecord::Base.transaction do
      currency!
      entity   = Entity.create!(code: ENTITY_CODE, name: "Bąk & Partners", active: true)
      accounts = chart!(ENTITY_CODE)
      count  = books!(accounts)
      group  = reports!(entity, accounts)
      admin = demo_admin!(entity, USERNAME, pro: false)
      pro   = demo_admin!(entity, PRO_USERNAME, pro: true)
      helper = demo_admin!(entity, UPLOAD_USERNAME, pro: false, access: :upload_receipts)
      # after the admins: the shoebox is stamped with the helper who
      # photographed it
      scans  = receipts!(entity, accounts, helper)

      puts <<~DONE

        Demo seeded.

          entity     #{entity.code} #{entity.name}
          accounts   #{accounts.size}
          entries    #{count}
          reports    #{group.name}: #{group.reports.count} (#{group.accounts.count} accounts)
          receipts   #{scans} (some linked to postings, some not)
          currencies PLN (added), EUR, GBP
          accounts   #{admin.username} (plain), #{pro.username} (journal entries),
                     #{helper.username} (the receipt uploader only) — all on
                     #{entity.code}, all writing nothing

        RATES ARE NOT SEEDED, on purpose — inventing reference data and labelling
        it "ecb" would be a lie a reader could check. A sterling report wants
        HMRC's GBP-based series, so the demo needs GBP->EUR and GBP->PLN:

            bin/rails exchange_rates:fetch

        The daily FillRateGapsJob covers it too, from the report dates below.

        /demo now offers a way in, and the landing page shows the button. The
        account has no usable password: it is reached only through that button,
        which posts and starts a session. Close it again with:

            bin/rails demo:destroy
      DONE
    end
  end

  desc "Remove the demo books and the demo account"
  task destroy: :environment do
    entity = Entity.find_by(code: ENTITY_CODE)
    admins = Admin.where(username: [ USERNAME, PRO_USERNAME, UPLOAD_USERNAME ], demo: true)
    abort "Nothing to remove — no entity #{ENTITY_CODE} and no demo admin." if entity.nil? && admins.none?

    ActiveRecord::Base.transaction do
      if entity
        codes = Account.for_entity_codes([ entity.code ]).pluck(:code)
        JournalEntry.joins(:postings)
                    .where(postings: { account_id: Account.where(code: codes).select(:id) })
                    .distinct.destroy_all
        Account.where(code: codes).destroy_all
        entity.destroy!
      end
      admins.each(&:destroy!)
    end

    puts "Demo removed. /demo no longer offers a way in."
  end

  desc "demo:destroy followed by demo:seed"
  task reset: :environment do
    Rake::Task["demo:destroy"].invoke rescue nil
    Rake::Task["demo:seed"].invoke
  end

  # ---------------------------------------------------------------- helpers

  # Adding a currency is data and an admin's job — the front page says so, so
  # the demo had better be able to demonstrate it.
  def currency!
    return if Currency.exists?(code: "PLN")

    Currency.create!(code: "PLN", symbol: "zł ", active: true)
    puts "  added PLN"
  end

  # Digit 1 is the type, digits 2-3 the entity, 4 the subcategory, 5-6 the
  # detail. Balance accounts (1,2,3) carry a currency; nominal ones (4,5,6) must
  # not — the model clears it either way, and that IS the multi-currency design:
  # an expense is not in a currency, the account that paid for it is.
  def chart!(e)
    defs = [
      [ "1#{e}001", "Bank account",           "EUR" ],
      [ "1#{e}002", "Client account Warsaw",  "PLN" ],
      [ "2#{e}001", "Business credit card",   "EUR" ],
      [ "3#{e}001", "Owner's capital",        "EUR" ],
      [ "4#{e}001", "Consulting fees",        nil   ],
      [ "4#{e}002", "Workshops",              nil   ],
      [ "5#{e}001", "Software subscriptions", nil   ],
      [ "5#{e}002", "Travel",                 nil   ],
      [ "5#{e}003", "Accountancy",            nil   ],
      [ "5#{e}004", "Bank charges",           nil   ]
    ]
    defs.to_h { |code, name, curr| [ code, Account.create!(code: code, name: name, currency: curr, active: true) ] }
  end

  # Nine months of a two-person consultancy: paid in złoty by a Warsaw client,
  # spending in euros on a card, moving money across when the złoty account gets
  # heavy. Amounts are in cents; the pairs are [złoty out, euros in] per
  # quarterly sweep.
  SWEEPS = [ [ 4_200_000,   986_577 ],
             [ 4_850_000, 1_133_974 ],
             [ 4_575_000, 1_048_954 ] ].freeze

  def books!(a)
    e = ENTITY_CODE
    n = entry!(Date.new(2025, 12, 1), "Opening capital",
               debit: [ a["1#{e}001"], 1_200_000 ], credit: [ a["3#{e}001"], 1_200_000 ])
    owed = 0   # what sits on the card, settled the following month as cards are

    (0..8).each do |i|
      month = Date.new(2025, 12, 1) >> i

      # Paid in złoty, into a złoty account. Nothing is converted, because
      # nothing needs to be — the account decides the currency of the entry.
      n += entry!(month + 9, "Retainer — Kowalski sp. z o.o.",
                  debit: [ a["1#{e}002"], 1_800_000 ], credit: [ a["4#{e}001"], 1_800_000 ])

      # Spent in euros, on a euro card, in the same set of books.
      charged = 8_900
      n += entry!(month + 3, "Software subscriptions",
                  debit: [ a["5#{e}001"], 8_900 ], credit: [ a["2#{e}001"], 8_900 ])

      if i.even?
        charged += 31_500
        n += entry!(month + 14, "Berlin — client workshop",
                    debit: [ a["5#{e}002"], 31_500 ], credit: [ a["2#{e}001"], 31_500 ])
        n += entry!(month + 17, "Workshop fee",
                    debit: [ a["1#{e}001"], 95_000 ], credit: [ a["4#{e}002"], 95_000 ])
      end

      if owed.positive?
        n += entry!(month + 21, "Credit card settled",
                    debit: [ a["2#{e}001"], owed ], credit: [ a["1#{e}001"], owed ])
      end
      owed = charged

      # Two balance accounts, two currencies, and no arithmetic relationship the
      # app insists on — the only entry shape it accepts as balanced without the
      # amounts matching, because they cannot.
      #
      # The pairs come from what HMRC actually published for those months, less
      # about 0.7% for the bank's spread, and the złoty side varies because a
      # business sweeps what has accumulated rather than the same figure three
      # times running.
      #
      # Both matter: the FX variance on a report IS the distance between the
      # rate you got and the rate the authority published, so inventing the pair
      # invents the variance. A flat 45,000 zł for €10,440 every quarter reads
      # as a 1.9% spread — a worse rate than any bank charges, on a suspiciously
      # identical transfer.
      if (i % 3) == 2 && (sweep = SWEEPS[i / 3])
        n += entry!(month + 25, "Warsaw → Berlin, quarterly sweep",
                    debit: [ a["1#{e}001"], sweep.last ], credit: [ a["1#{e}002"], sweep.first ])
      end

      # An entry is not two lines. One payment settling several things at once
      # is ordinary bookkeeping and the demo has to show it: one balance
      # account, any number of nominal ones, balancing across the whole entry
      # rather than pair by pair.
      if (i % 3) == 1
        n += entry_multi!(month + 27, "Quarter's odds and ends, one payment",
                          debits: [ [ a["5#{e}001"], 8_900 ],
                                    [ a["5#{e}002"], 12_400 ],
                                    [ a["5#{e}004"], 1_200 ] ],
                          credits: [ [ a["1#{e}001"], 22_500 ] ])
      end

      next unless (i % 4) == 3

      # The same on the way in: one transfer arrives, two things earned it.
      n += entry_multi!(month + 11, "Autumn programme — fees and workshop",
                        debits:  [ [ a["1#{e}001"], 268_000 ] ],
                        credits: [ [ a["4#{e}001"], 185_000 ],
                                   [ a["4#{e}002"], 83_000 ] ])

      n += entry!(month + 20, "Bookkeeping — quarterly",
                  debit: [ a["5#{e}003"], 45_000 ], credit: [ a["1#{e}001"], 45_000 ])
    end

    n
  end

  # Something to open. A report group is a set of accounts plus the periods you
  # want them over, so this is a profit and loss: the income and expense
  # accounts, read across two quarters that both have entries in them.
  #
  # It also earns the demo its rates. Rates::GapFinder decides what is WANTED
  # from the date spans of saved reports, not from postings, so these two rows
  # are what makes the daily fill fetch GBP→EUR and GBP→PLN at all.
  def reports!(entity, accounts)
    group = ReportGroup.create!(entity: entity, name: "2026", position: 1,
                                description: "Profit and loss, by quarter")

    nominal = accounts.values.select { |a| a.income? || a.expense? }.sort_by(&:code)
    nominal.each_with_index do |account, i|
      ReportGroupAccount.create!(report_group: group, account: account, position: i + 1)
    end

    Report.create!(report_group: group, name: "Q1",
                   start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31))
    Report.create!(report_group: group, name: "Q2",
                   start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30))
    group
  end

  # Receipts, drawn rather than photographed. A demo needs documents that look
  # like documents — a reader clicks one expecting a scan — but shipping real
  # photographs would be either somebody's actual paperwork or a stock image
  # with a licence attached. So they are generated: a plain slip with the
  # trader, the date and the amount on it.
  #
  # Some are linked to the posting they belong to and one or two are not, which
  # is the ordinary state of any real receipts folder and the thing the
  # "unlinked" filter exists for.
  def receipts!(entity, accounts, helper)
    software = accounts["5#{ENTITY_CODE}001"]
    travel   = accounts["5#{ENTITY_CODE}002"]
    made     = 0

    Posting.where(account: [ software, travel ]).includes(:journal_entry).find_each do |posting|
      je = posting.journal_entry
      next unless je.entry_date.year == 2026 && je.entry_date.month <= 4

      trader = posting.account_id == software.id ? "Cloudkit BV" : "Deutsche Bahn"
      made  += 1 if receipt!(entity, trader, je.entry_date, posting.amount, posting: posting)
    end

    # The shoebox: arrived, photographed, nobody has said what they are yet.
    #
    # uploaded_by is what the standalone uploader lists, and only these carry
    # it, because Receipt#link_to_posting clears uploaded_by the moment a
    # receipt is booked. A receipt in someone's shoebox has an owner; a booked
    # one belongs to the entry. Stamping the linked ones above would contradict
    # the model.
    [ [ "Ferner Papeterie",  Date.new(2026, 5, 14),  2_340 ],
      [ "Taxi Warszawa",     Date.new(2026, 6,  2),  8_900 ],
      [ "Cafe Mokka",        Date.new(2026, 6, 18),  1_780 ],
      [ "Hotel Astoria",     Date.new(2026, 7,  3), 41_500 ],
      [ "Ruch Kiosk",        Date.new(2026, 7, 21),  6_420 ],
      [ "Deutsche Bahn",     Date.new(2026, 8,  5), 13_900 ] ].each do |trader, date, cents|
      made += 1 if receipt!(entity, trader, date, cents, uploaded_by: helper)
    end
    made
  end

  def receipt!(entity, trader, date, cents, posting: nil, uploaded_by: nil)
    file = draw_slip(trader, date, cents)
    return false if file.nil?

    Receipt.create!(entity: entity, posting: posting, receipt_date: date,
                    uploaded_by: uploaded_by,
                    title: "#{trader} #{date.strftime('%d.%m.%Y')}", scan: file)
    file.close!
    true
  end

  # ImageMagick is already a hard dependency — ReceiptUploader shells out to it
  # for every upload — so drawing a slip costs nothing extra. If it is missing
  # the demo simply has no receipts rather than failing to seed.
  def draw_slip(trader, date, cents)
    tmp = Tempfile.new([ "demo-receipt", ".jpg" ])
    text = "#{trader}\n#{date.strftime('%d.%m.%Y')}\n\nEUR #{'%.2f' % (cents / 100.0)}\n\n* * *\nthank you"

    ok = system("magick", "-size", "440x600", "canvas:#fdfcf6", "-gravity", "north",
                "-pointsize", "26", "-fill", "#3a382f",
                "-annotate", "+0+70", text, tmp.path, err: File::NULL)
    return tmp if ok && File.size?(tmp.path)

    tmp.close!
    nil
  rescue Errno::ENOENT
    nil
  end

  # Any number of postings on either side. Refuses to write an entry that does
  # not balance rather than leaving one for a reader to find: a demo whose books
  # do not add up argues against the app.
  def entry_multi!(date, memo, debits:, credits:)
    d = debits.sum(&:last)
    c = credits.sum(&:last)
    raise "#{memo} does not balance: #{d} debit vs #{c} credit" unless d == c

    je = JournalEntry.new(entry_date: date, memo: memo)
    debits.each  { |acct, cents| je.postings.build(account: acct, entry_type: :debit,  amount: cents) }
    credits.each { |acct, cents| je.postings.build(account: acct, entry_type: :credit, amount: cents) }
    je.save!
    1
  end

  def entry!(date, memo, debit:, credit:)
    je = JournalEntry.new(entry_date: date, memo: memo)
    je.postings.build(account: debit.first,  entry_type: :debit,  amount: debit.last)
    je.postings.build(account: credit.first, entry_type: :credit, amount: credit.last)
    je.save!
    1
  end

  # No usable password. The only way into this account is the /demo button,
  # which starts the session server-side, so there is no credential to leak,
  # guess, or reuse anywhere else.
  def demo_admin!(entity, username, pro:, access: :read_only)

    # preferred_currency explicitly, because the demo never goes through
    # SessionsController#create and so never gets the login-time default.
    #
    # claimed_at set directly: demo is never a draft — it has no email to
    # confirm and can never log in as anyone real — so leaving this nil would
    # send a stranger into the claim flow instead of the dashboard.
    admin = Admin.new(username: username, demo: true, sudo: false,
                      preferred_currency: "EUR", show_journal_entries: pro,
                      claimed_at: Time.current)
    admin.password = SecureRandom.hex(32)
    admin.save!
    AdminEntity.create!(admin: admin, entity: entity, access_level: access)
    admin
  end
end
