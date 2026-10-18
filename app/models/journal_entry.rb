# frozen_string_literal: true

class JournalEntry < ApplicationRecord

  has_many :postings,
           class_name: 'Posting', 
           foreign_key: :journal_entry_id,
           inverse_of: :journal_entry, 
           dependent: :destroy
  accepts_nested_attributes_for :postings, allow_destroy: true, reject_if: proc { |attrs|
display = attrs['amount_display'].to_s.strip
all_blank = attrs['account_id'].blank? && attrs['amount'].blank? && display.blank?
new_record_zero = attrs['id'].blank? && display.present? && display.gsub(/[^0-9.,]/, '').gsub(',', '.').to_f.zero?
all_blank || new_record_zero
}

  validates :entry_date, presence: true
  before_validation :derive_closing_period, if: :closing_entry?
  validate :closing_period_is_ordered, if: :closing_entry?
  # No `on:` restriction — a BRAND NEW entry posting into the app's own
  # retained-earnings account is exactly as much "not yours to write" as editing
  # an existing one. See #posts_to_locked_retained_earnings?.
  validate :app_owned_close_is_read_only
  # prepend: so it runs before `has_many :postings, dependent: :destroy` — that
  # cascade removes the very postings this guard inspects.
  before_destroy :prevent_user_destroy_of_app_owned_close, prepend: true
  validate :postings_must_balance
  validate :must_have_balance_sheet_posting
  validate :single_balance_account_with_nominals
  validate :vat_leg_currency_matches_the_balance_leg
  validate :tax_codes_are_usable, if: :tax_coded?
  validate :transfer_accounts_valid, if: :transfer_mode?
  validate :postings_same_group
  validate :cross_entity_real_leg_is_nominal
  
  before_save :auto_post_if_balanced

  scope :posted, -> { where(posted: true) }
  scope :unposted, -> { where(posted: false) }
  scope :by_date_range, ->(start_date, end_date) { where(entry_date: start_date..end_date) }
  scope :default_order, -> { order(posted: :asc, id: :desc, entry_date: :desc) }
  scope :for_entity, ->(entity) {
    joins(:postings => :account)
      .where("accounts.code LIKE ?", "_#{entity.code}%")
      .distinct
  }
  scope :search_filter, ->(term) {
    return all if term.blank?
    q = "%#{term}%"
    cents = CurrencyConfig.parse_to_cents(term)
    base = joins(postings: :account).distinct
    if cents
      base.where(
        "journal_entries.memo ILIKE ? OR journal_entries.journal_reference ILIKE ? OR accounts.code ILIKE ? OR accounts.name ILIKE ? OR postings.amount = ?",
        q, q, q, q, cents
      )
    else
      base.where(
        "journal_entries.memo ILIKE ? OR journal_entries.journal_reference ILIKE ? OR accounts.code ILIKE ? OR accounts.name ILIKE ?",
        q, q, q, q
      )
    end
  }
  
  attr_accessor :from_account_id, :to_account_id,
                :transfer_amount, :transfer_amount_display,
                :target_amount, :target_amount_display

  def post!
    return false unless balanced?
    #update(posted: true)
    update_column(:posted, true)
  end
  def unpost!
    #update(posted: false)
    update_column(:posted, false)
  end
  
  def total_debits
    postings.debit.sum(:amount)
  end

  def total_credits
    postings.credit.sum(:amount)
  end

  def balanced?
    active_postings = postings.reject(&:marked_for_destruction?)
    return false if active_postings.empty?

    # Cross-currency transfer: exactly 2 postings, different currencies, both
    # balance sheet accounts
    if active_postings.size == 2
      currencies = active_postings.map { |p| p.currency.presence }.compact.uniq
      if currencies.size == 2
        all_balance_sheet = active_postings.all? do |p|
          acct = account_for_posting(p)
          acct&.balance_account?
        end
        # Valid cross-currency: one debit, one credit, both positive amounts
        if all_balance_sheet
          has_debit = active_postings.any?(&:debit?)
          has_credit = active_postings.any?(&:credit?)
          all_positive = active_postings.all? { |p| p.amount.to_i > 0 }
          return true if has_debit && has_credit && all_positive
        end
      end
    end

    # Regular balance check...
    #
    # NEVER a derived VAT leg. It sits on a control account, so it is a
    # balance-sheet row and matched here — and a reverse charge's legs are in
    # the SCHEME's currency, which is not the entry's. Taking one of those as
    # the default handed every nominal row a currency the entry was never in.
    default_currency = active_postings.find { |p|
      !p.tax_leg? && account_for_posting(p)&.balance_account?
    }&.currency

    balances = Hash.new(0)
    active_postings.each do |posting|
      amt = posting.amount || 0
      acct = account_for_posting(posting)
      currency = if acct&.income? || acct&.expense? || acct&.personal?
                   default_currency
                 else
                   posting.currency.presence || default_currency
                 end
      if posting.debit?
        balances[currency] += amt
      else
        balances[currency] -= amt
      end
    end
    balances.values.all?(&:zero?)
  end
              
  def transfer?
    postings.count == 2 && 
      postings.all? { |p| p.account.account_type.in?(%w[asset liability]) }
  end

  def deposit?(bank_account)
    posting = postings.find_by(account_id: bank_account.id)
    posting&.debit?
  end

  def withdrawal?(bank_account)
    posting = postings.find_by(account_id: bank_account.id)
    posting&.credit?
  end
  
  def transfer_amount_display=(value)
    self.transfer_amount = CurrencyConfig.parse_to_cents(value)
  end
  def transfer_amount_display
    return nil if transfer_amount.nil?
    transfer_amount / 100.0
  end 
  # for cross currency, what arrives in account
  def target_amount_display=(value)
    self.target_amount = CurrencyConfig.parse_to_cents(value)
  end
  def target_amount_display
    return nil if target_amount.nil?
    target_amount / 100.0
  end
  def transfer_mode?
    from_account_id.present? || to_account_id.present?
  end   

  def cross_currency_transfer?
    return false unless from_account_id.present? && to_account_id.present?
    currencies = Account.where(id: [from_account_id, to_account_id]).pluck(:currency).compact.uniq
    currencies.size == 2
  end
  def implied_exchange_rate
    return nil unless transfer_amount.present? && transfer_amount > 0
    return nil unless target_amount.present? && target_amount > 0
    (target_amount.to_f / transfer_amount.to_f).round(6)
  end

  def transfer_amount_display_formatted(locale: I18n.locale)
    format_amount_for_display(transfer_amount_display, locale: locale)
  end
  def target_amount_display_formatted(locale: I18n.locale)
    format_amount_for_display(target_amount_display, locale: locale)
  end

  def display_currency
    currencies = postings.map(&:currency).compact.uniq
    currencies.size == 1 ? currencies.first : nil
  end

  # Part of a cross-entity transaction if any of its postings carries a
  # cross_entity_link_id — a bridge posting linking to a counterpart entry in
  # another entity. See Posting for the full picture.
  def cross_entity?
    postings.any?(&:cross_entity_linked?)
  end

  # The counterpart journal entries reachable through this entry's bridge
  # postings. Id-only pluck, then one load of the few counterparts.
  def cross_entity_linked_entries
    link_ids = postings.filter_map(&:cross_entity_link_id)
    return JournalEntry.none if link_ids.empty?

    counterpart_je_ids = Posting.where(cross_entity_link_id: link_ids)
                                     .where.not(journal_entry_id: id)
                                     .distinct
                                     .pluck(:journal_entry_id)
    JournalEntry.where(id: counterpart_je_ids)
  end

  # True when this entry is the ORIGIN side of a cross-entity transaction — it
  # holds the gift bridge, a personal account (601), where the counterpart holds
  # the equity bridge (304). For the show/edit views deciding which side they
  # are looking at; the delete cascade itself is per-posting in
  # Posting#handle_cross_entity_link_on_destroy.
  def cross_entity_origin?
    postings.any? { |p| p.cross_entity_linked? && p.account&.personal? }
  end

  # For a COUNTERPART (JE₂), the origin JE₁ reached via its equity bridge's
  # linked gift, so "edit JE₂" can route to the single edit surface. nil when
  # this entry is itself the origin, or not cross-entity.
  def cross_entity_counterpart_origin
    return nil if !cross_entity? || cross_entity_origin?
    bridge = postings.detect { |p| p.cross_entity_linked? && p.account&.equity? }
    bridge&.cross_entity_counterpart&.journal_entry
  end

  # True when this entry moves into a locked retained-earnings account — the
  # year-end flow generated it rather than a user building it by hand.
  #
  # Checks BOTH what is already saved (SQL-side, so a brand new record with
  # nothing loaded still sees it) and what is currently built in memory. Both
  # are needed: saved state alone misses a new entry outright, and in-memory
  # state alone lets an edit that REMOVES the retained-earnings leg from an
  # already-saved app-owned entry look untouched, unlocking the rest of the
  # entry for editing.
  def posts_to_locked_retained_earnings?
    return true if postings.any? { |p| !p.marked_for_destruction? && retained_earnings_account_ids.include?(p.account_id) }
    persisted? && Posting.where(journal_entry_id: id, account_id: retained_earnings_account_ids).exists?
  end

  # The same thing, minus the app's own rewrites: read-only to users, writable
  # by the recalculation and by reopening a year, which set the Current flag.
  def app_owned_close?
    return false if Current.app_closing_entry_write
    posts_to_locked_retained_earnings?
  end

  # Builds, updates and removes this entry's derived VAT legs, in place.
  # Returns any control accounts it had to create, so the caller can say so.
  #
  # Called explicitly and always BEFORE the caller works out the bank leg: that
  # leg is the sum of the others and must come to the GROSS, which it only does
  # once the legs are among them. A callback would hide that ordering, and would
  # also fire on post! and the year-end paths, which never touch VAT.
  def derive_tax_legs
    rows  = postings.reject { |p| p.marked_for_destruction? || p.tax_leg? }
    codes = TaxCode.lookup(rows.map(&:tax_code_id), on: entry_date)
    # Whatever is left here at the end belongs to a row that was deleted or
    # decoded. Keyed by the net posting ITSELF where the link is only in memory:
    # a leg built moments ago has no foreign key, and keying on the id alone
    # made a second pass build a second leg.
    orphans = postings.select(&:tax_leg?).group_by { |leg|
      leg.association(:tax_for_posting).target || leg.tax_for_posting_id
    }
    created = []

    rows.each do |row|
      mine = orphans.delete(row) || (row.id.present? ? orphans.delete(row.id) : nil) || []
      code = codes[row.tax_code_id]
      # Handed to the row, so the form that renders it afterwards does not
      # load the same code again, once per row.
      row.association(:tax_code).target = code if code
      reconcile_tax_legs(row, mine, code ? tax_legs_wanted(row, code, created) : [])
    end

    orphans.each_value { |legs| legs.each(&:mark_for_destruction) }
    created
  end

  # Whether anything in this entry carries a VAT code — the cheap test the
  # controllers use before asking for the work.
  def tax_coded?
    postings.any? { |p| !p.marked_for_destruction? && p.tax_code_id.present? }
  end

private

  # The currency every leg of an entry with nominals is in: that of the balance
  # row's ACCOUNT. The posting's own currency column is only filled at
  # validation, after derivation has run, so it cannot be read here.
  def entry_currency
    postings.reject { |p| p.marked_for_destruction? || p.tax_leg? }
            .filter_map { |p| account_for_posting(p) }
            .find(&:balance_account?)
            &.currency
  end

  # What this row's leg should be, and the net it is left with. Gross is the
  # invariant: edit the VAT figure and the net moves, never the gross, so the
  # bank leg goes on matching the statement.
  def tax_legs_wanted(row, code, created)
    account = account_for_posting(row)
    return [] if account.nil? || account.entity_code.blank?

    # A reverse charge posts nothing. The VAT is owed and reclaimed in the same
    # breath, so the ledger has no use for it; the return works it out from the
    # net, translated at the authority's accepted rate for the entry date like
    # every other figure in a tax report. Which is also what lets it be paid
    # from an account in any currency: nothing is converted at save.
    return [] if code.reverse_charge?

    # On an update that did not resubmit the amount, the column holds the NET
    # of the last derivation; the gross is that plus the leg it already has.
    row.gross_for_tax ||=
      row.amount_changed? || row.amount_submitted? || row.new_record? ? row.amount.to_i
                                                                        : row.gross_amount.to_i
    return [] if row.gross_for_tax.zero?

    # A refund, or a commission line inside a split income: the bank form flips
    # a row's side with a minus sign, which normalize_negative_amounts applies
    # only at validation. The VAT reverses with the net, so the leg takes the
    # flipped side now and the row keeps its sign for the normaliser.
    gross = row.gross_for_tax.abs
    side  = row.gross_for_tax.negative? ? flip(row.entry_type) : row.entry_type

    tax =
      if code.amount_is_tax?
        gross
      else
        typed = row.tax_amount_from_form || code.tax_from_gross(gross)
        # More than the whole amount is a mistake, refused rather than quietly
        # replaced. It used to become zero, which sent the figure to the net
        # box and left nothing to notice.
        if typed.negative? || typed > gross
          row.tax_amount_invalid = true
          typed = code.tax_from_gross(gross)
        end
        typed
      end

    net = gross - tax
    row.amount = row.gross_for_tax.negative? ? -net : net
    return [] unless tax.positive?

    # Same side as the net row: a purchase debits both, the bank carries both.
    [ vat_leg(account, code, code.direction, tax, side, created) ]
  end

  # One query per (scheme, direction), however many rows share it.
  def vat_leg(net_account, code, direction, amount, entry_type, created)
    @_vat_accounts ||= {}
    key = [ net_account.entity_code, code.scheme, direction ]
    account = @_vat_accounts[key] ||= begin
      resolved = Account.resolve_vat_account(entity_code: net_account.entity_code,
                                             scheme: code.scheme, direction: direction)
      created << resolved if resolved.previously_new_record?
      resolved
    end

    { account: account, amount: amount, entry_type: entry_type, currency: account.currency }
  end

  # Matched by ACCOUNT, not position: a reverse charge has two legs and only the
  # account says which. Updated rather than replaced, so the id survives an edit.
  def reconcile_tax_legs(row, existing, wanted)
    by_account = existing.group_by(&:account_id)

    wanted.each do |spec|
      leg = (by_account[spec[:account].id] || []).shift
      if leg
        leg.assign_attributes(spec)
      else
        postings.build(spec).tax_for_posting = row
      end
    end

    by_account.each_value { |legs| legs.each(&:mark_for_destruction) }
  end

  def flip(entry_type) = entry_type.to_s == "debit" ? :credit : :debit

  # What a posting alone cannot check: the entry's date, currency and shape.
  # One query for the codes, one for the entities, however many rows.
  def tax_codes_are_usable
    rows = postings.reject { |p| p.marked_for_destruction? || p.tax_leg? }
                   .select { |p| p.tax_code_id.present? }
    return if rows.empty?

    codes    = TaxCode.where(id: rows.map(&:tax_code_id)).index_by(&:id)
    accounts = rows.index_with { |row| account_for_posting(row) }
    schemes  = filed_schemes_by_entity(accounts.values.compact.map(&:entity_code).uniq)
    rows.each do |row|
      account = accounts[row]
      next if account.nil?
      code = codes[row.tax_code_id]
      name = "#{account.code} #{account.name}"

      # A rate that had not started, or was withdrawn. Moving the date does it.
      if code.nil? || !code.on?(entry_date)
        errors.add(:base, I18n.t("journal_entries.errors.tax_code_date",
                                 account: name, date: I18n.l(entry_date, format: :short_date)))
        next
      end

      if row.tax_amount_invalid
        errors.add(:base, I18n.t("journal_entries.errors.tax_amount_exceeds_gross",
                                 account: name))
      end

      # A row that already carried this code keeps it after the business has
      # stopped filing: the entry belongs to a year it did file. Only a code
      # being PUT on a row is held to today's registration.
      filed = schemes.fetch(account.entity_code, [])
      filed |= [ code.scheme ] unless row.tax_code_id_changed?
      case account.tax_code_problem(code, filed_schemes: filed)
      when :not_nominal
        errors.add(:base, I18n.t("journal_entries.errors.tax_code_not_nominal", account: name))
      when :direction
        # A sale code on an expense derived its leg into the OUTPUT VAT account,
        # so the return showed tax owed on money that had been spent.
        errors.add(:base, I18n.t("journal_entries.errors.tax_code_direction",
                                 account: name, code: code.label))
      when :scheme
        errors.add(:base, I18n.t("journal_entries.errors.tax_code_scheme",
                                 account: name,
                                 scheme: TaxSchemeConfig.scheme_label(code.scheme)))
      end

      # A control account holds one currency, the one the authority is paid in,
      # so a leg in another currency could not be posted. A reverse charge
      # posts no leg, so it is free of this.
      wanted = TaxSchemeConfig.currency_for(code.scheme)
      if !code.reverse_charge? &&
         entry_currency.present? && wanted.present? && entry_currency != wanted
        errors.add(:base, I18n.t("journal_entries.errors.tax_code_currency",
                                 scheme: TaxSchemeConfig.scheme_label(code.scheme),
                                 scheme_currency: wanted, entry_currency: entry_currency))
      end

      # JE₂ only. cross_entity_real_leg_is_nominal already refuses a balance VAT
      # leg there; this says it in VAT's words and also catches the EÜR case,
      # where the control account IS nominal and that rule would let it through.
      #
      # NOT the donor's side: a gift in the entry does not stop them reclaiming
      # VAT on their own expense row beside it.
      if cross_entity_counterpart?
        errors.add(:base, I18n.t("journal_entries.errors.tax_code_cross_entity", account: name))
      end
    end
  end

  # The receiving side, identified as cross_entity_real_leg_is_nominal does it:
  # it holds the equity bridge, where the origin holds the personal gift.
  def cross_entity_counterpart?
    postings.any? { |p| p.cross_entity_linked? && p.account&.equity? }
  end

  # One query. Accounts have no entity_id — digits 2 and 3 of the code are it.
  def filed_schemes_by_entity(entity_codes)
    return {} if entity_codes.empty?
    Entity.where(code: entity_codes).pluck(:code, :tax_schemes).to_h
  end


  # A pro may mark a hand-built entry as closing a financial year, so it counts
  # towards the dashboard's "closed up to" note. They should not have to work
  # out the period: it ends on the entry date and runs a year back unless they
  # say otherwise. YearEndService entries always carry both dates already, so
  # this never touches them.
  def derive_closing_period
    self.period_end   ||= entry_date
    self.period_start ||= (period_end - 1.year + 1.day) if period_end
  end

  def closing_period_is_ordered
    return if period_start.blank? || period_end.blank?
    return if period_start <= period_end
    errors.add(:period_start, I18n.t("journal_entries.errors.closing_period_order"))
  end

  def retained_earnings_account_ids
    @retained_earnings_account_ids ||= Account.retained_earnings.pluck(:id)
  end

  # A closing entry that posts into the app's own retained-earnings account
  # belongs to the app — never a user's to create OR edit by hand, whatever they
  # tick closing_entry to. Left open, a hand-built one would either sit there
  # unmanaged forever or be silently destroyed at the next recalculation.
  #
  # Reopening a year is the one legitimate way back, and it removes the whole
  # period's closing entries together, all currencies: deleting a single
  # currency's close would leave the year looking closed while that currency's
  # income and expenses were still sitting in the P&L.
  def app_owned_close_is_read_only
    return unless app_owned_close?
    errors.add(:base, I18n.t("journal_entries.errors.closing_entry_managed"))
  end

  def prevent_user_destroy_of_app_owned_close
    return unless app_owned_close?
    errors.add(:base, I18n.t("journal_entries.errors.closing_entry_managed"))
    throw :abort
  end


  # A cross-entity COUNTERPART (JE₂, holding an equity bridge with a link) must
  # have its real leg on a NOMINAL income/expense account, never a balance
  # account. Backstop for the JS trigger, which only fires on this shape.
  def cross_entity_real_leg_is_nominal
    bridge = postings.detect { |p| p.cross_entity_linked? && p.account&.equity? }
    return unless bridge
    postings.each do |p|
      next if p == bridge
      next if p.account.nil? || p.account.income? || p.account.expense?
      errors.add(:base, I18n.t("postings.errors.cross_entity_nominal_only"))
      break
    end
  end

  def format_amount_for_display(val, locale: I18n.locale)
    CurrencyConfig.format_display(val, locale: locale)
  end

  def auto_post_if_balanced
    self.posted = balanced? unless posted_changed?
  end

  def postings_must_balance
    active_postings = postings.reject(&:marked_for_destruction?)
    if active_postings.empty?
      errors.add(:base, I18n.t("journal_entries.errors.no_postings"))
      return
    end
    errors.add(:base, I18n.t("journal_entries.errors.must_balance")) unless balanced?
  end
  
  # One query for the whole entry's accounts, and the answer is handed to each
  # posting's association so nothing downstream — a validation, a view — asks
  # again. Reading `posting.account` to find the missing ones was itself the
  # query per row this exists to avoid.
  def account_for_posting(posting)
    association = posting.association(:account)
    return association.target if association.loaded?
    return nil if posting.account_id.blank?

    @_posting_account_cache ||= Account.where(id: postings.map(&:account_id).compact.uniq)
                                       .index_by(&:id)
    account = @_posting_account_cache[posting.account_id] || posting.account
    association.target = account if account
    account
  end
      
  def must_have_balance_sheet_posting
    active_postings = postings.reject(&:marked_for_destruction?)
    return if active_postings.empty?
    # If any account is blank, account_id presence validation covers it
    return if active_postings.any? { |p| account_for_posting(p).nil? }
    # If all amounts are blank, amount_must_be_valid covers it
    return if active_postings.all? { |p| p.amount.blank? }

    unless active_postings.any? { |p| account_for_posting(p)&.balance_account? }
      errors.add(:base, I18n.t("journal_entries.errors.no_balance_sheet"))
    end
  end

  # An entry with nominal postings may hold exactly ONE balance-sheet account.
  # Nominals carry no currency and borrow the balance leg's; "exactly one" is
  # also what keeps a bank entry self-balancing.
  #
  # A DERIVED VAT leg does not count — it is computed into the control account
  # for the scheme, in the scheme's currency, so it cannot break the currency
  # guarantee. One typed BY HAND still does, and should: a VAT leg with no code
  # behind it would never reach the return.
  #
  # Only bites where the control account is on the balance sheet. Under a
  # nominal scheme (vat_accounts: nominal, German EÜR) it is an income or
  # expense account, so this rule never sees it and a hand-typed one is not
  # refused — Reports::VatReturn's `unassigned` is what catches that.
  def single_balance_account_with_nominals
    active_postings = postings.reject(&:marked_for_destruction?)
    return if active_postings.empty?

    nominal, balance = [], []
    active_postings.each do |posting|
      account = account_for_posting(posting)
      next if account.nil?
      nominal << account if account.income? || account.expense? || account.personal?
      balance << account if account.balance_account? && !posting.tax_leg?
    end

    # DISTINCT accounts, not rows: the rule is about several balance accounts in
    # one entry, and two rows on the SAME one is still one account. Counting
    # rows refused that, and named the account twice in the message saying so.
    balance = balance.uniq
    return if nominal.empty? || balance.size <= 1

    # Named, because the message left the user to work out which of six rows.
    errors.add(:base, I18n.t("journal_entries.errors.multiple_balance_accounts",
                             accounts: balance.map { |a| "#{a.code} #{a.name}" }.to_sentence))
  end

  # Backstop for the exemption above. Nothing a user can do should reach it:
  # the leg is derived into an account in the scheme's currency, and a code may
  # only be used on an entry in that currency. If those two ever drift apart the
  # entry is refused with both currencies named, rather than going unbalanced.
  def vat_leg_currency_matches_the_balance_leg
    active_postings = postings.reject(&:marked_for_destruction?)
    legs = active_postings.select { |p| p.tax_leg? && account_for_posting(p)&.balance_account? }
    return if legs.empty?

    real = active_postings.find { |p|
      !p.tax_leg? && account_for_posting(p)&.balance_account?
    }
    return if real.nil? || real.currency.blank?

    legs.each do |leg|
      next if leg.currency.blank? || leg.currency == real.currency
      errors.add(:base, I18n.t("journal_entries.errors.vat_leg_currency",
                               account: account_for_posting(leg)&.code,
                               currency: leg.currency,
                               bank_currency: real.currency))
    end
  end

  def transfer_accounts_valid
    errors.add(:to_account_id, I18n.t("journal_entries.errors.account_blank")) if to_account_id.blank?
    errors.add(:from_account_id, I18n.t("journal_entries.errors.account_blank")) if from_account_id.blank?
    if from_account_id.present? && to_account_id.present? && from_account_id.to_s == to_account_id.to_s
      errors.add(:to_account_id, I18n.t("journal_entries.errors.accounts_same"))
    end
    if transfer_amount.blank? || transfer_amount <= 0
      errors.add(:transfer_amount_display, I18n.t("journal_entries.errors.amount_zero"))
    end
    if cross_currency_transfer? && (target_amount.blank? || target_amount <= 0)
      errors.add(:target_amount_display, I18n.t("journal_entries.errors.target_amount_zero"))
    end
  end

  # A journal entry must belong to a single consolidation group. Each group
  # keeps its own self-balancing books — it files its own taxes and balance
  # sheet — so a transaction spanning two groups breaks a group's standalone
  # balance. Entities in the SAME group may freely share an entry; genuinely
  # separate groups are joined instead by two linked entries, and an ungrouped
  # entity is its own group.
  #
  # Enforced for everyone, sudo included: an accounting rule, not an access
  # rule.
  def postings_same_group
    active_postings = postings.reject(&:marked_for_destruction?)
    return if active_postings.size < 2

    entity_codes = active_postings.filter_map do |posting|
      account_for_posting(posting)&.entity_code
    end.uniq
    return if entity_codes.size < 2

    group_keys = Entity.group_key_for_codes(entity_codes).values.uniq
    errors.add(:base, I18n.t("journal_entries.errors.single_group")) if group_keys.size > 1
  end
end
