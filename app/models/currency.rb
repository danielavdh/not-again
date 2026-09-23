# frozen_string_literal: true

# The currencies this installation supports.
#
# Two constraints shape everything here:
#
# 1. symbol_for runs on EVERY formatted amount — a trial balance formats
# hundreds — so this needs a memoised lookup, never a query per call.
# 2. It is read VERY EARLY, before a database is guaranteed to exist. Touching
# one at load time breaks db:create, assets:precompile and CI without a
# database, so it must be lazy and must survive the table not being there at
# all.
#
# Everything reaches this through CurrencyConfig, which keeps the fallback.
# Nothing else should read this class directly.
class Currency < ApplicationRecord

  # How long a process may serve a stale list. The TTL is what covers OTHER
  # processes — the web container cannot see the worker's write, and
  # after_commit only clears the cache in the process that did the writing.
  CACHE_TTL = 60

  # ISO 4217 decimal places, for the currencies that are not 2. Everything else
  # on earth is 2, so only the exceptions are listed — about 23 codes out of
  # ~180. A code that is not here gets 2, which is right for every currency
  # this app is likely to meet and wrong only for one ISO has since invented:
  # that is a pull request, not a runtime guess.
  #
  # 0 means the stored integer IS the whole unit — a yen has no subunit at all,
  # Iceland's aurar were abolished in 2003. 3 means thousandths: a Kuwaiti
  # dinar is 1000 fils.
  MINOR_UNITS = {
    # no subunit
    "BIF" => 0, "CLP" => 0, "DJF" => 0, "GNF" => 0, "ISK" => 0, "JPY" => 0,
    "KMF" => 0, "KRW" => 0, "PYG" => 0, "RWF" => 0, "UGX" => 0, "VND" => 0,
    "VUV" => 0, "XAF" => 0, "XOF" => 0, "XPF" => 0,
    # thousandths
    "BHD" => 3, "IQD" => 3, "JOD" => 3, "KWD" => 3, "LYD" => 3, "OMR" => 3,
    "TND" => 3
  }.freeze

  DEFAULT_MINOR_UNIT = 2

  validates :code, presence: true, length: { is: 3 },
                   format: { with: /\A[A-Z]{3}\z/, message: :invalid },
                   uniqueness: { case_sensitive: false }
  validates :symbol, presence: true
  validates :minor_unit, inclusion: { in: 0..3 }

  normalizes :code, with: ->(c) { c.to_s.strip.upcase }

  # Derived, never asked. Nobody adding a currency knows how many decimal
  # places ISO gives it, and a wrong answer is money wrong by a factor of a
  # hundred with nothing on screen to show for it.
  #
  # Re-derived on a RENAME too: correcting "JPZ" to "JPY" already cascades
  # every account, posting and rate (#migrate_dependents_to_new_code), and the
  # decimal places have to move with them or the corrected code keeps the wrong
  # one forever.
  before_validation :derive_minor_unit, if: -> { new_record? || code_changed? }

  scope :active, -> { where(active: true) }

  # Display order is a RULE, not something an admin sets: everything USED by an
  # account, alphabetically, then everything else, alphabetically. Two groups
  # and no third. A currency promotes itself the moment an account is opened in
  # it, so nobody hand-ranks a growing list and one admin cannot reorder every
  # other admin's report columns.
  #
  # An editable `position` column was dropped rather than left unread. Do not
  # reintroduce it as a form field.
  def self.ordered
    used = used_codes

    all.to_a.sort_by { |c| [ used.include?(c.code) ? 0 : 1, c.code ] }
  end

  # Which currencies an account is actually kept in. One query, and the answer
  # to "used" everywhere it is asked.
  #
  # `scope:` narrows it to the accounts an ADMIN can see. Without it this reads
  # every account in the installation — right for the global display ORDER,
  # wrong for "which currencies are relevant to you", where an admin whose one
  # business keeps euros would be offered CHF and GBP belonging to entities they
  # cannot open.
  def self.used_codes(scope: nil)
    (scope || Account).where.not(currency: nil).distinct.pluck(:currency).to_set
  end

  # The same rule, but for the memoised symbol lookup, which must not load
  # models. One extra query per cache fill, not per call.
  def self.in_display_order
    ordered
  end

  after_commit :expire_cache

  # A code change corrects what carries the old string rather than orphaning it:
  # every account, posting and exchange rate under the old code migrates
  # (#migrate_dependents_to_new_code). The lock below decides WHO may trigger
  # that — full-access admin or sudo — never whether dependants get fixed.
  after_update :migrate_dependents_to_new_code, if: :saved_change_to_code?

  # Deactivating drops the currency from CurrencyConfig.available, which is
  # exactly what the picker in admins/show.html.erb offers — an admin whose
  # preference still names it would see no option selected (reading as
  # "automatic" by accident) while default_display_currency kept returning
  # the retired code. Clearing it makes "automatic" the honest, actual state.
  after_update :clear_preference_on_deactivation, if: -> { saved_change_to_active? && !active? }

  # Once settled, the code and symbol are not a full-access admin's to change. A
  # currency is GLOBAL: one admin adds it and it appears in every other admin's
  # pickers and report columns.
  #
  # Settled means a POSTING carries it. An account with no postings yet is not
  # settled — it holds no real money, and
  # Account#currency_immutable_with_postings applies the same rule one level
  # down.
  #
  # A FETCHED RATE IS NOT USE and must not lock or protect anything: rates are
  # derived, so adding a currency and letting the nightly fetch run must not
  # turn Delete into Deactivate overnight for a currency nobody has booked a
  # penny in.
  #
  # Sudo is not bound by this at all — someone has to be able to fix a genuine
  # mistake after real postings exist.
  def settled?
    posted?
  end

  # How recently a posting must have been CREATED for retiring the currency to
  # be refused. Two months — long enough to cover a quarter not yet filed.
  RECENTLY_POSTED_WITHIN = 2.months

  # Keyed on created_at, not entry_date: entry_date is user-editable, so a
  # backdated entry must not dodge this. Counts unposted drafts too — an
  # admin mid-entry is exactly who this protects.
  def recently_active?
    Posting.joins(:journal_entry)
           .where(currency: code, journal_entries: { created_at: RECENTLY_POSTED_WITHIN.ago.. })
           .exists?
  end

  # Is any MONEY denominated in this currency — an account or a posting.
  # Deleting one that is in use would leave those records rendering with no
  # symbol and sorting last, silently, because CurrencyConfig.symbol_for returns
  # "" for anything it does not know.
  #
  # Deliberately WIDER than #posted?: a delete has nowhere to migrate its
  # dependants TO, unlike an edit, which cascades — so an account with no
  # postings yet still has to block a delete, or there would be no code left for
  # it to point at. Stored exchange rates deliberately do not count.
  def in_use?
    Account.where(currency: code).exists? ||
      Posting.where(currency: code).exists? ||
      Admin.where(preferred_currency: code).exists?
  end

  # Is any POSTING denominated in this currency — narrower than #in_use? on
  # purpose. An account can exist with this currency and no postings yet; it
  # holds no real money, and an edit now cascades onto its own #currency anyway.
  # Only once a posting carries the code does correcting it become sudo's alone.
  def posted?
    Posting.where(currency: code).exists?
  end

  class << self
    # { code => symbol } in display order, FROZEN, or nil when the table cannot
    # be read. nil is not an error: it is "no database yet", and CurrencyConfig
    # falls back to its seed constant. A Hash rather than pairs because
    # symbol_for runs on every formatted amount, and building one per call would
    # allocate a hash per cell of a trial balance.
    #
    # EVERY currency, ACTIVE OR NOT. Deactivating is about what may be CHOSEN,
    # never about what a stored figure looks like: filtering by active stripped
    # the symbol from every amount in a deactivated currency, globally, for
    # every admin. Rendering asks this; only the PICKERS ask cached_available.
    def cached_symbols
      load_if_stale
      @rows&.transform_values(&:first)
    end

    # Active only, in display order — the list a dropdown may offer.
    def cached_available
      load_if_stale
      @rows&.select { |_code, (_symbol, active)| active }&.keys
    end

    def load_if_stale
      return unless @rows.nil? || @loaded_at.nil? ||
                    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @loaded_at) > CACHE_TTL

      @rows      = load_rows
      @loaded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def expire_cache
      @rows = @loaded_at = nil
    end

    private

    # Rescues broadly ON PURPOSE and returns nil rather than raising. This runs
    # before db:create, during assets:precompile, and in CI with no database —
    # all legitimate, and none of which should fail because the app wanted to
    # know what a euro sign looks like. It also covers the deploy window where
    # the code is new and the migration has not run.
    #
    # EMPTY IS NIL, not "this installation supports no currencies". Zero
    # currencies is never a valid state, and an empty table is exactly what a
    # database built from schema.rb has, because the seeding lives in the
    # migration — a fresh install, a restored dump and the test database all
    # arrive here. Returning {} made every currency dropdown empty and every
    # amount lose its symbol, silently.
    def load_rows
      return nil unless table_exists?

      ordered.to_h { |c| [ c.code, [ c.symbol, c.active? ] ] }.presence&.freeze
    rescue ActiveRecord::ActiveRecordError
      nil
    end
  end

  private

  def expire_cache
    self.class.expire_cache
  end

  def derive_minor_unit
    self.minor_unit = MINOR_UNITS.fetch(code.to_s.strip.upcase, DEFAULT_MINOR_UNIT)
  end

  def clear_preference_on_deactivation
    Admin.where(preferred_currency: code).update_all(preferred_currency: nil)
  end

  # Runs after ANY successful code change — a full-access admin fixing an
  # unposted typo, or sudo correcting one that already reached real postings.
  # Both need the same three tables brought into line.
  def migrate_dependents_to_new_code
    old_code, new_code = saved_change_to_code
    Account.where(currency: old_code).update_all(currency: new_code)
    Posting.where(currency: old_code).update_all(currency: new_code)
    Admin.where(preferred_currency: old_code).update_all(preferred_currency: new_code)
    migrate_exchange_rates(old_code, new_code)
  end

  # Unlike accounts and postings, a stray rate row can collide with one that
  # ALREADY exists correctly under the new code — fixing "EUT" to "EUR" will
  # almost always find real EUR history sitting there. A collision means the old
  # row is a redundant duplicate, so it is dropped rather than left stuck on a
  # code that no longer exists.
  #
  # A failed UPDATE poisons the rest of the surrounding Postgres transaction
  # until something rolls it back, so rescuing in Ruby is not enough on its own:
  # each row's attempt gets its own SAVEPOINT (requires_new: true), and a
  # collision unwinds only that row.
  def migrate_exchange_rates(old_code, new_code)
    [ :from_currency, :to_currency ].each do |column|
      ExchangeRate.where(column => old_code).find_each do |rate|
        ActiveRecord::Base.transaction(requires_new: true) do
          rate.update_column(column, new_code)
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid
        rate.destroy
      end
    end
  end
end
