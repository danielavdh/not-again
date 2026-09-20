# frozen_string_literal: true

class Account < ApplicationRecord

  include AccountCoding

  enum :account_type, { asset: 1, liability: 2, equity: 3, income: 4, expense: 5, personal: 6 }

  belongs_to :parent, class_name: 'Account', optional: true
  has_many :children, class_name: 'Account', foreign_key: :parent_id, dependent: :nullify
  has_many :postings, class_name: 'Posting', foreign_key: :account_id, dependent: :restrict_with_error
  has_many :report_group_accounts, class_name: 'ReportGroupAccount', foreign_key: :account_id, dependent: :destroy

  before_validation :set_account_type_from_code, if: :code_changed?
  before_validation :clear_currency_for_nominal_accounts
  before_validation :inherit_parent_currency_for_balance_accounts
  validates :code, presence: true, 
                   length: { is: 6 },
                   format: { with: /\A[1-6]\d{5}\z/, message: I18n.t("accounts.errors.code_format") },
                   uniqueness: true
  validates :name, presence: true
  validates :currency, absence: true, unless: :currency_required?
  validates :deduction_percentage, numericality: { only_integer: true, in: 1..99 }, allow_nil: true
  validate :currency_immutable_with_postings, if: :currency_changed?
  validate :currency_must_be_active, if: :currency_changed?
  validate :code_prefix_immutable_with_postings, if: :code_changed?
  validate :not_deactivated_with_a_balance, if: -> { persisted? && active_changed? && !active? }
  validate :entity_code_matches_creator, on: :create, if: :creating_admin
  validate :parent_cannot_be_grandparent
  validate :code_not_in_retained_earnings_range, unless: :locked?

  before_update :prevent_locked_update
  before_destroy :prevent_locked_destroy

  scope :active, -> { where(active: true) }
  scope :locked, -> { where(locked: true) }
  scope :retained_earnings, -> { locked.where(account_type: :equity) }
  scope :by_type, ->(type) { where(account_type: type) }
  scope :balance_accounts, -> { where(account_type: [:asset, :liability, :equity]) }
  scope :by_currency, ->(curr) { where(currency: curr) }
  scope :roots, -> { where(parent_id: nil) }
  scope :ordered, -> { order(:code) }
  # all accounts that are not parents
  scope :leaf_accounts, -> { 
    where.not(id: Account.where.not(parent_id: nil).select(:parent_id).distinct) 
  }
  # Accounts that are not children themselves (can be parents)
  scope :potential_parents, -> {
    where(parent_id: nil)
  }
  scope :for_entity_codes, ->(codes) { where("SUBSTRING(code, 2, 2) IN (?)", Array(codes)) }
  
  # Validation to ensure new accounts use creator's entity code
  attr_accessor :creating_admin

  def balance_account?
    asset? || liability? || equity?
  end

  def nominal_account?
    !balance_account?
  end

  def has_postings?
    postings.exists?
  end

  # What a bank entry is CALLED on this account. Money in is a deposit and money
  # out a withdrawal, except on an equity account, where the same two movements
  # are the owner drawing money out and putting money in, so the words swap
  # round.
  def entry_label(entry_type)
    return entry_type.to_s unless equity?

    entry_type.to_s == "deposit" ? "drawing" : "contribution"
  end

  # The OTHER thing they could have meant — what the "switch to…" link offers.
  def flip_entry_label(entry_type)
    if equity?
      entry_type.to_s == "deposit" ? "contribution" : "drawing"
    else
      entry_type.to_s == "deposit" ? "withdrawal" : "deposit"
    end
  end

  # Scheme and category as the one value the tax-category select round-trips.
  # Nil unless BOTH are set — one without the other is not an assignment.
  # AccountsController#explode_tax_combined! splits it back apart.
  def tax_category_combined
    return nil unless tax_scheme.present? && tax_category_key.present?

    "#{tax_scheme}::#{tax_category_key}"
  end
  def deletable?
    return false if postings.exists?
    return false if Posting.where(account_id: children.select(:id)).exists?
    true
  end
  # Memory-efficient balance calculation (used in accounts.show)
  def balance(start_date: nil, end_date: nil)
    scope = postings.joins(:journal_entry).where(journal_entries: { posted: true })
    scope = scope.where('journal_entries.entry_date >= ?', start_date) if start_date
    scope = scope.where('journal_entries.entry_date <= ?', end_date) if end_date
    debit_int  = Posting.entry_types[:debit]
    credit_int = Posting.entry_types[:credit]
    result = scope.select(
        "SUM(CASE WHEN postings.entry_type = #{debit_int}  THEN postings.amount ELSE 0 END) as debits",
        "SUM(CASE WHEN postings.entry_type = #{credit_int} THEN postings.amount ELSE 0 END) as credits"
      ).take

    debits = result&.debits || 0
    credits = result&.credits || 0

#      (debit_normal? ? debits - credits : credits - debits) / 100.0
    (debit_normal? ? debits - credits : credits - debits)
  end
  # Personal (drawings) accounts are debit-normal, like expenses: money out is
  # the norm, a refund the exception. The one Ruby definition #balance,
  # Account.balances_for and CustomReport all read.
  def debit_normal?
    asset? || expense? || personal?
  end

  # Batch balance calculation - returns hash of account_id => balance
  def self.balances_for(account_ids, start_date: nil, end_date: nil)
    return {} if account_ids.empty?

    scope = Posting.joins(:journal_entry, :account)
      .where(account_id: account_ids)
      .where(journal_entries: { posted: true })
    scope = scope.where('journal_entries.entry_date >= ?', start_date) if start_date
    scope = scope.where('journal_entries.entry_date <= ?', end_date) if end_date

    # CHANGE: Group by BOTH account_id AND account_type
    debit_int  = Posting.entry_types[:debit]
    credit_int = Posting.entry_types[:credit]
    debit_normal_types = Account.account_types.values_at("asset", "expense", "personal")

    raw = scope.group('postings.account_id, accounts.account_type').select(
      'postings.account_id',
      'accounts.account_type',
      "SUM(CASE WHEN postings.entry_type = #{debit_int}  THEN postings.amount ELSE 0 END) as debits",
      "SUM(CASE WHEN postings.entry_type = #{credit_int} THEN postings.amount ELSE 0 END) as credits"
    )

    raw.each_with_object({}) do |row, result|
      debit_normal = row.account_type.in?(debit_normal_types)
      result[row.account_id] = debit_normal ?
        (row.debits - row.credits) : (row.credits - row.debits)
    end
  end
   
  # No tree walk: only leaves are tagged, so an account's category is its own or
  # it has none.
  def effective_tax_scheme
    tax_scheme.presence
  end
  def effective_tax_category_key
    tax_category_key.presence
  end
  # Convenience: the resolved catalogue row for a given country + year.
  def effective_tax_category(country_code:, tax_year:)
    scheme = effective_tax_scheme
    key    = effective_tax_category_key
    return nil if scheme.blank? || key.blank?
    TaxCategory.resolve(country_code: country_code,
                             scheme: scheme,
                             year: tax_year,
                             key: key)
  end
  # An account with no children. Postings only ever land on leaves, and the
  # tree is at most one level deep (parent_cannot_be_grandparent).
  def leaf?
    children.none?
  end

  # Only LEAF income/expense accounts carry a tax category. A parent groups
  # accounts the way the owner thinks about the business; a tax category groups
  # them the way the authority does, and the two need not coincide — one
  # parent's children can be depreciation, interest and bad debt, which are
  # three different boxes. Tagging a parent would assert an alignment that is
  # not there.
  def tax_taggable?
    (income? || expense?) && leaf?
  end

  # Releases one entity's accounts from a scheme: the account keeps its balances
  # and everything else, it just stops being tagged.
  #
  # Every path that can make a tax scheme stop applying to an entity must call
  # this — unsubscribing it (EntitiesController) and deleting its now-empty
  # report group directly (ReportGroupsController) — or an account is left
  # tagged to a scheme nothing points at any more.
  #
  # Scoped to one entity's accounts: another entity may still file the same
  # scheme and must not lose its own tagging. One UPDATE, nothing loaded.
  def self.release_from_scheme(entity_code:, scheme:)
    return if scheme.blank?

    for_entity_codes([ entity_code ])
      .where(tax_scheme: scheme)
      .update_all(tax_scheme: nil, tax_category_key: nil)
  end

  # Unmapped means NO REPORT GROUP CLAIMS IT — not "has no tag", and not
  # "belongs to a scheme the entity no longer files".
  #
  # The group is the right test because the group is what makes an account
  # visible and reportable, and a group outlives its subscription in exactly one
  # case: it has reports. An account tagged to a dropped scheme whose group
  # SURVIVED is still in use — its figures are recomputed into that historical
  # report every time it is opened, so offering it elsewhere would let a
  # reassignment empty the report with nothing said. An account whose group went
  # with the subscription has nowhere left to be seen, and is exactly what this
  # must surface.
  #
  # Leaf accounts only: they are the ones that can hold postings and the only
  # ones that carry a tax category, so a blank key here is genuinely unassigned
  # with nothing inherited to check. includes(:parent) so the view can show the
  # parent as context without an N+1.
  #
  # Two queries, nothing loaded: the claimed (entity, scheme) pairs, then one
  # row-value NOT IN.
  def self.unmapped_for_tax(entity_codes:)
    return none if entity_codes.blank?

    scope = active
      .leaf_accounts
      .where(account_type: [account_types[:income], account_types[:expense]])
      .for_entity_codes(entity_codes)

    claimed = ReportGroup.tax_reports
                              .joins(:entity)
                              .where(entities: { code: entity_codes })
                              .pluck(Arel.sql("entities.code"), :tax_scheme)

    return scope.includes(:parent).order(:code) if claimed.empty?

    # The accounts some group has claimed, as a subquery — bound values, no
    # built SQL, and nothing loaded to find them.
    taken = claimed.map { |code, scheme|
      scope.where(tax_scheme: scheme).where("SUBSTRING(code, 2, 2) = ?", code)
    }.reduce(:or)

    scope.where.not(id: taken.select(:id))
         .includes(:parent)
         .order(:code)
  end

private
  
  def set_account_type_from_code
    self.account_type = derived_account_type if derived_account_type
  end
  def clear_currency_for_nominal_accounts
    self.currency = nil unless currency_required?
  end
  def currency_required?
    asset? || liability? || equity?
  end
  def inherit_parent_currency_for_balance_accounts
    return unless parent_id.present? && currency_required?
    return unless parent&.currency.present?
    self.currency = parent.currency
  end
  def currency_immutable_with_postings
    return unless persisted? && postings.exists?
    errors.add(:currency, I18n.t("accounts.errors.currency_immutable"))
  end
  def currency_must_be_active
    return if currency.blank? || CurrencyConfig.available.include?(currency)
    errors.add(:currency, I18n.t("accounts.errors.currency_not_active"))
  end
  def code_prefix_immutable_with_postings
    return unless persisted? && postings.exists?
    old_prefix = code_was&.first(3)
    new_prefix = code&.first(3)
    if old_prefix != new_prefix
      errors.add(:code, I18n.t("accounts.errors.code_prefix_immutable"))
    end
  end
  # Making an account inactive hides it from every report and picker, so a
  # balance still on it would silently vanish from the trial balance, P&L and
  # balance sheet. Bring it to zero first — a closing entry, or move the balance
  # elsewhere.
  def not_deactivated_with_a_balance
    errors.add(:active, I18n.t("accounts.errors.balance_not_zero")) unless balance.zero?
  end
  # An account may only be created inside an entity its creator may WRITE to — a
  # read_only or upload_receipts link is not enough, even when the same admin
  # holds full access somewhere else. Sudo is unrestricted.
  def entity_code_matches_creator
    return unless creating_admin
    return if creating_admin.sudo?

    writable_codes = creating_admin.writable_entity_codes
    account_entity = entity_code if code.present? && code.length >= 3
    unless writable_codes.include?(account_entity)
      errors.add(:code, I18n.t("accounts.errors.entity_code_mismatch", codes: writable_codes.join(', ')))
    end
  end
  def parent_cannot_be_grandparent
    return unless parent_id.present?
    if parent&.parent_id.present?
      errors.add(:parent_id, I18n.t("accounts.errors.parent_grandparent"))
    end
  end

  def code_not_in_retained_earnings_range
    return unless code =~ /\A3\d{2}9\d{2}\z/
    reserved = "#{code[0..3]}00–#{code[0..3]}99"
    errors.add(:code, I18n.t("accounts.errors.reserved_for_retained_earnings", range: reserved))
  end

  def prevent_locked_update
    return unless locked?
    errors.add(:base, I18n.t("accounts.errors.locked"))
    throw :abort
  end

  def prevent_locked_destroy
    return unless locked?
    errors.add(:base, I18n.t("accounts.errors.locked"))
    throw :abort
  end

end
