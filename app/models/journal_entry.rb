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
    default_currency = active_postings.find { |p| 
      acct = account_for_posting(p)
      acct&.balance_account?
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

private

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
  
  def account_for_posting(posting)
    @_posting_account_cache ||= begin
      missing_ids = postings.reject(&:marked_for_destruction?)
        .select { |p| p.account.nil? && p.account_id.present? }
        .map(&:account_id).uniq
      missing_ids.any? ? Account.where(id: missing_ids).index_by(&:id) : {}
    end
    posting.account || @_posting_account_cache[posting.account_id]
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

  def single_balance_account_with_nominals
    active_postings = postings.reject(&:marked_for_destruction?)
    return if active_postings.empty?

    accounts = active_postings.filter_map { |p| account_for_posting(p) }
    has_nominal = accounts.any? { |a| a.income? || a.expense? || a.personal? }
    balance_count = accounts.count { |a| a.balance_account? }

    if has_nominal && balance_count > 1
      errors.add(:base, I18n.t("journal_entries.errors.multiple_balance_accounts"))
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
