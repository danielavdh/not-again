# frozen_string_literal: true

class Posting < ApplicationRecord

  enum :entry_type, { debit: 0, credit: 1 }

  belongs_to :journal_entry, 
             class_name: 'JournalEntry',
             inverse_of: :postings, 
             foreign_key: :journal_entry_id
  belongs_to :account, class_name: 'Account', 
             foreign_key: :account_id

  has_many :receipts, class_name: "Receipt", 
           foreign_key: :posting_id, 
           dependent: :nullify,
           inverse_of: :posting
  
  accepts_nested_attributes_for :receipts, reject_if: proc { |attrs|
             attrs['scan'].blank? && attrs['title'].blank?
           }

  before_validation :normalize_negative_amounts
  before_validation :set_currency_from_account
  before_validation :clear_currency_for_nominal_accounts
  validates :currency, presence: true, length: { is: 3 }, if: :requires_currency?
  validates :entry_type, presence: true
  validate :amount_must_be_valid
  validate :currency_matches_account_if_required
  validate :cross_entity_link_consistent, if: :cross_entity_linked?
  validate :cross_entity_capital_currency, if: :cross_entity_linked?
  validates :account_id, presence: { message: "must be selected" }
  before_destroy :unlink_receipts
  before_destroy :destroy_deduction_pair
  before_destroy :handle_cross_entity_link_on_destroy
  after_create :link_existing_receipt, if: -> { existing_receipt_id.present? }

  scope :by_currency, ->(curr) { where(currency: curr) }
  scope :for_account, ->(account_id) { where(account_id: account_id) }
  scope :debit, -> { where(entry_type: :debit) }
  scope :credit, -> { where(entry_type: :credit) }
  
  attr_accessor :amount_display, :existing_receipt_id

  # One row of a ledger page. The query plucks columns rather than loading
  # Posting objects, and the Struct names them; it is still indexable by
  # position, so the running-balance and CSV code that reads row[6] keeps
  # working.
  LedgerRow = Struct.new(
    :journal_entry_id, :date, :memo, :journal_reference,
    :description, :reference, :debit, :amount, :currency,
    :posting_id, :counter_accounts, :transaction_type
  ) do
    def debit?
      debit
    end

    # The single counter account, when there is exactly one — the case the
    # ledger shows by name and builds its edit links from.
    def sole_counter_account
      counter_accounts.first if counter_accounts.size == 1
    end

    # What currency to show this line in. A posting on a nominal account has
    # none of its own — it takes the currency of the balance-sheet account it
    # was entered against, which is the sole counter account.
    def display_currency
      currency || sole_counter_account&.[](7)
    end
  end

  # Pagination is ledger_base_scope's; this does the plucking, and the CSV
  # export uses it too.
  def self.ledger_base_scope(account_id, start_date: nil, end_date: nil)
    scope = joins(:journal_entry)
             .where(account_id: account_id)
             .where(journal_entries: { posted: true })

    scope = scope.where(journal_entries: { entry_date: start_date.. }) if start_date
    scope = scope.where(journal_entries: { entry_date: ..end_date }) if end_date

    scope.order('journal_entries.entry_date DESC', 'journal_entries.id DESC')
  end
  def self.ledger_data_from_scope(paginated_scope, account)
    postings = paginated_scope.pluck(
      'journal_entries.id',
      'journal_entries.entry_date',
      'journal_entries.memo',
      'journal_entries.journal_reference',
      'postings.description',
      'postings.reference',
      :entry_type,
      :amount,
      :currency,
      :id
    )

    journal_entry_ids = postings.map(&:first).uniq

    counter_scope = where(journal_entry_id: journal_entry_ids)
                      .where.not(account_id: account.id)
                      .joins(:account)

    if account.income? || account.expense? || account.personal?
      counter_scope = counter_scope.where(accounts: { account_type: [:asset, :liability, :equity] })
    end

    counter_postings = counter_scope.pluck(
      :journal_entry_id,
      'accounts.id',
      'accounts.code',
      'accounts.name',
      'accounts.account_type',
      :entry_type,
      :amount,
      :currency,
      :description
    )

    counter_accounts_by_je = counter_postings.group_by(&:first)

    postings.map do |je_id, date, memo, je_ref, post_desc, post_ref, entry_type, amount, currency, posting_id|
      counter_accounts = counter_accounts_by_je[je_id] || []
      is_debit = (entry_type == "debit")
      LedgerRow.new(je_id, date, memo, je_ref, post_desc, post_ref, is_debit, amount, currency,
                    posting_id, counter_accounts,
                    determine_transaction_type(counter_accounts, is_debit, account))
    end
  end
  def self.determine_transaction_type(counter_accounts, is_debit, account)
    return 'Unknown' if counter_accounts.empty?

    if account.balance_account?
      # Rails 8.1 returns enum keys as strings when plucking joined-table
      # columns
      balance_sheet_types = %w[asset liability equity]
      balance_sheet_counters = counter_accounts.count { |ca| balance_sheet_types.include?(ca[4]) }
      return 'Journal Entry' if balance_sheet_counters >= 2
      all_balance_sheet = balance_sheet_counters == counter_accounts.size
      all_balance_sheet ? 'Transfer' : (is_debit ? 'Deposit' : 'Withdrawal')
    else
      'Transfer'
    end
  end

  # linked to a nominal account's posting. Used to build edit links on nominal
  # ledgers. Returns the edit path type of balance account
  def self.balance_account_edit_type(counter_accounts)
    return nil if counter_accounts.empty?
    return 'journal_entry' if counter_accounts.size >= 2
    counter_accounts.first[5] == "debit" ? 'deposit' : 'withdrawal'
  end

  # original method, without pagination, for csv export
  def self.ledger_data_with_counter_accounts(account_id, start_date: nil, end_date: nil)
    account = Account.find(account_id)
    scope = ledger_base_scope(account_id, start_date: start_date, end_date: end_date)
    ledger_data_from_scope(scope, account)
  end

  def amount_display=(value)
    self.amount = CurrencyConfig.parse_to_cents(value)
  end
  def amount_display
    return nil if amount.nil?
    amount / 100.0
  end    
  def amount_display_for(expected_type)
    return nil if amount.nil? || amount == 0
    val = amount / 100.0
    if entry_type == expected_type
      val.abs
    else
      -val.abs
    end
  end
  def amount_display_formatted(expected_type = nil, locale: I18n.locale)
    val = expected_type ? amount_display_for(expected_type) : amount_display
    CurrencyConfig.format_display(val, locale: locale)
  end
  
  def self.currency_join_sql
    <<~SQL
      LEFT JOIN LATERAL (
        SELECT p2.currency
        FROM postings p2
        JOIN accounts a2 ON a2.id = p2.account_id
        WHERE p2.journal_entry_id = postings.journal_entry_id
        AND p2.currency IS NOT NULL
        AND a2.account_type IN (1, 2, 3)
        LIMIT 1
      ) balance_currency ON true
    SQL
  end

  def self.effective_currency_sql
    "COALESCE(postings.currency, balance_currency.currency)"
  end

  # A cross-entity transaction is two SEPARATE single-entity journal entries,
  # one per entity, joined by a shared cross_entity_link_id on their bridge
  # postings — the paying entity's gift/private posting (6xx) and the receiving
  # entity's capital posting (3xx). Unlike the split-posting deduction_pair_id,
  # the two postings live in DIFFERENT journal entries.
  #
  # Destroying a bridge is asymmetric: the gift side deletes the counterpart
  # entry, the capital side only severs the link.
  def cross_entity_linked?
    cross_entity_link_id.present?
  end

  # The bridge posting on the other side of the link (in the counterpart JE),
  # or nil. One query, nothing else loaded.
  def cross_entity_counterpart
    return nil if cross_entity_link_id.blank?
    Posting.where(cross_entity_link_id: cross_entity_link_id)
                .where.not(id: id)
                .first
  end

private
  
  def amount_must_be_valid
    if amount.blank?
      errors.add(:amount_display, I18n.t("postings.errors.amount_blank"))
    elsif !amount.is_a?(Numeric)
      errors.add(:amount_display, I18n.t("postings.errors.amount_not_a_number"))
    elsif amount.negative? || (amount.zero? && !journal_entry&.closing_entry?)
      # A closing entry may carry a zero retained-earnings leg (a break-even
      # year): the leg still has to exist as the entry's balance-sheet posting.
      errors.add(:amount_display, I18n.t("postings.errors.amount_not_positive"))
    end
  end

  def normalize_negative_amounts
    return unless amount.present? && amount < 0
    self.amount = amount.abs
    self.entry_type = debit? ? :credit : :debit
  end
  
  def set_currency_from_account
    return unless account
    if account.balance_account?
      self.currency = account.currency
    end
  end
  def clear_currency_for_nominal_accounts
    return unless account
    if account.income? || account.expense? || account.personal?
      self.currency = nil
    end
  end
  
  def requires_currency?
    return false unless account
    account.balance_account?
  end
  
  def currency_matches_account_if_required
    return unless account&.currency.present?
    return unless account.balance_account?
    if currency != account.currency
      errors.add(:currency, I18n.t("postings.errors.currency_mismatch", currency: account.currency))
    end
  end

  def destroy_deduction_pair
    return if deduction_pair_id.blank?
    Posting.where(deduction_pair_id: deduction_pair_id)
                .where.not(id: id)
                .each do |partner|
                  partner.update_column(:deduction_pair_id, nil)
                  partner.destroy
                end
  end

  # Asymmetric by side, and the rule has to hold on EVERY destroy path (form
  # _destroy, controller destroy, purge, console):
  # - GIFT side (personal 6xx) is the ORIGIN: the counterpart JE₂ received
  # capital from a gift that is vanishing, so destroy the whole counterpart
  # entry, posted or not — the deliberate unpost of JE₁ is the gate.
  # - CAPITAL side (equity 3xx): only sever the link, leaving JE₁'s gift as a
  # plain posting. SQL-only, the counterpart is never loaded into Ruby.
  def handle_cross_entity_link_on_destroy
    return if cross_entity_link_id.blank?
    if account&.personal?
      cross_entity_counterpart&.journal_entry&.destroy!
    else
      Posting.where(cross_entity_link_id: cross_entity_link_id)
                  .where.not(id: id)
                  .update_all(cross_entity_link_id: nil)
    end
  end

  # A persisted link must bind this bridge posting to EXACTLY ONE counterpart,
  # in a different journal entry and a different entity, with a mirrored amount
  # — equal magnitude, opposite side. Runs only once a counterpart is persisted,
  # so it never blocks the atomic two-sided creation: it catches later edits and
  # data corruption. Currency-match-to-bank and the nominal-only real leg are
  # enforced by the creation service.
  def cross_entity_link_consistent
    # A coupled save writes one side before the other, and the concern re-
    # verifies the mirror once both are written — so do not fire on the
    # transient mid-transaction state.
    return if Current.skip_cross_entity_consistency

    partners = Posting.where(cross_entity_link_id: cross_entity_link_id)
                           .where.not(id: id)
                           .to_a
    return if partners.empty? # counterpart not yet built — leave it to the service

    consistent = partners.one? &&
                 (partner = partners.first) &&
                 partner.journal_entry_id != journal_entry_id &&
                 partner.amount == amount &&
                 partner.entry_type != entry_type &&
                 partner.account&.entity_code != account&.entity_code

    unless consistent
      errors.add(:base, I18n.t("postings.errors.cross_entity_link_invalid"))
    end
  end

  # The 304 capital's currency must match the currency of the balance (bank)
  # account in the linked JE₁. Only the equity capital side checks, and only
  # once its counterpart is persisted so JE₁'s bank is reachable. Stable, so NOT
  # gated by the coupled-save skip flag.
  def cross_entity_capital_currency
    return unless account&.equity?
    gift = cross_entity_counterpart
    return unless gift
    bank = gift.journal_entry&.postings&.detect { |p| p != gift && p.account&.balance_account? }
    return if bank.nil? || bank.currency.blank?
    if currency != bank.currency
      errors.add(:base, I18n.t("postings.errors.cross_entity_currency_mismatch", currency: bank.currency))
    end
  end

  def unlink_receipts
    receipts.each do |receipt|
      receipt.unlink_from_posting!
    end
  end
  def link_existing_receipt
    existing_receipt_id.to_s.split(',').map(&:strip).each do |rid|
      Receipt.find_by(id: rid)&.update!(posting_id: id)
    end
  end

end

