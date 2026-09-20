# frozen_string_literal: true

class BaseController < ApplicationController
  include Pagy::Method
  require_admin
  before_action :require_accounts_access
  before_action :require_claim_completed
  before_action :require_otp_verification
  before_action :require_terms_agreement
  before_action :require_write_access

  layout 'accounting'

  helper_method :available_currencies,
                :report_currencies,
                :accessible_entity_ids,
                :accessible_accounts,
                :accessible_entities,
                :entities_for_receipt_upload,
                :accessible_journal_entries,
                :accessible_postings,
                :accessible_receipts,
                :accessible_report_groups,
                :accessible_reports,
                :current_admin_entity_codes,
                :default_display_currency,
                :multi_entity_admin?,
                :upload_receipts_only?,
                :read_only_admin?,
                :can_upload_receipts?,
                :can_edit_for_entity?,
                :writable_accounts,
                :writable_entity_codes,
                :last_closed_on,
                :recent_archives

  private

  def remap_pair_id(original_pair_id, map)
    return nil if original_pair_id.blank?
    map[original_pair_id] ||= SecureRandom.uuid
  end

  # An edit to a posted entry landing in an already-closed or already-archived
  # period. Two questions, one lock:
  #
  # 1. Does THIS entity have a closing entry covering the date? Closing is per
  # entity — only that entity's own closing entry can need rebuilding, never a
  # sibling's.
  # 2. Is there an archive for that scope and calendar year? If so it just went
  # stale and is regenerated in place, same key.
  #
  # Both run under an advisory lock on the scope the entity was in on that date,
  # so a correction cannot race a close of the same books.
  def refresh_affected_closing_entry(je)
    return nil if je.closing_entry?

    entity_code = je.postings.joins(:account)
                    .limit(1)
                    .pluck(Arel.sql("SUBSTRING(accounts.code, 2, 2)"))
                    .first
    return nil unless entity_code
    entity = Entity.find_by(code: entity_code)
    return nil unless entity

    Archives::Lock.with(entity.scope_key_on(je.entry_date)) do
      message = rebuild_own_closing_entry(entity, je)
      Archives::YearEnd.refresh(entity.scope_key_on(je.entry_date), je.entry_date)
      message
    end
  end

  # Only THIS entity's own closing entry, never a sibling's — a closing entry
  # is computed purely from its own entity's postings.
  def rebuild_own_closing_entry(entity, je)
    affected = app_generated_closing_entries(entity.code)
      .where("period_start <= ? AND period_end >= ?", je.entry_date, je.entry_date)
      .where.not(id: je.id)
      .first
    return nil unless affected

    period_start = affected.period_start
    period_end   = affected.period_end

    # The app rewriting its own closing entries — see
    # JournalEntry#app_owned_close?
    Current.app_closing_entry_write = true
    begin
      app_generated_closing_entries(entity.code)
        .where(period_start: period_start, period_end: period_end)
        .destroy_all

      YearEndService.new(entity: entity, start_date: period_start, end_date: period_end).call
    ensure
      Current.app_closing_entry_write = false
    end

    t("journal_entries.closing_entry_updated_suffix")
  end

  # Closing entries this app generated — those whose equity leg sits on a locked
  # retained-earnings account in the reserved 3EE9xx range
  # (Account#code_not_in_retained_earnings_range). A pro's hand-built closing
  # entry posts to an equity account of their own and is never rebuilt or
  # destroyed by the automated flow.
  def app_generated_closing_entries(entity_code)
    app_generated_closing_entries_for_codes([ entity_code ])
  end

  def app_generated_closing_entries_for_codes(entity_codes)
    JournalEntry
      .where(closing_entry: true, posted: true)
      .joins(postings: :account)
      .where("SUBSTRING(accounts.code, 2, 2) IN (?)", entity_codes)
      .where(id: Posting.where(account_id: Account.retained_earnings.select(:id))
                             .select(:journal_entry_id))
      .distinct
  end

  # An admin with no entity links has nowhere to be: root IS this controller, so
  # redirecting there would loop. Ending the session is loop-free and honest.
  #
  # A refusal has to answer in the format that was ASKED FOR. fetch() follows a
  # redirect, so a guard that only knows how to redirect reaches the JavaScript
  # as a GET of an HTML page — either a 406, or a lump of markup handed to
  # .json(). 403 for a refusal, because that is what it is; the HTML half still
  # redirects, because a person needs somewhere to be.
  def deny_access(message, path)
    respond_to do |format|
      format.html { redirect_to path, alert: message }
      format.json { render json: { errors: [ message ] }, status: :forbidden }
      format.any  { head :forbidden }
    end
  end

  def require_accounts_access
    unless current_admin&.can_access_accounts?
      terminate_session
      deny_access(t("access.no_access"), root_path)
    end
  end
  # require_otp_verification lives in the Authentication concern: the second
  # factor belongs to the admin session, so the controllers outside this one
  # (admins, help, password reset) require it too.
  def require_write_access
    if upload_receipts_only?
      redirect_to upload_standalone_receipts_path
    elsif demo_admin?
      return if demo_may_look?
      deny_access(t("access.read_only_deny"), dashboard_path)
    elsif read_only_admin?
      return if request.get? && !%w[new edit].include?(action_name)
      return if tax_export_request?
      deny_access(t("access.read_only_deny"), dashboard_path)
    end
  end

  
  def tax_export_request?
    action_name == "tax_export"
  end

  # Override in controllers that need to find accounts
  def set_account
    @account = find_accessible_account(params[:id])
  end
  def find_accessible_account(id)
    accessible_accounts.find(id)
  rescue ActiveRecord::RecordNotFound
    deny_access(t("access.account_not_found"), accounts_path)
    nil
  end

  # Write guards are per entity, not per admin. Reading is scoped by
  # accessible_*, writing by writable_*, and these filters are what stop a
  # full_access link on one entity from unlocking writes on an entity the same
  # admin only reads.

  # @account is already set (and already proved accessible) by set_account.
  def require_writable_account
    return if @account.nil? # set_account already redirected
    deny_write unless writable_accounts.exists?(@account.id)
  end

  def require_writable_journal_entry
    return if @journal_entry.nil?
    deny_write unless writable_journal_entries.exists?(@journal_entry.id)
  end

  # For the forms that submit account ids: every account a posting is aimed at
  # has to be one this admin may write to. One query for the lot, no loading.
  def require_writable_posting_accounts(account_ids)
    ids = Array(account_ids).reject(&:blank?).map(&:to_s).uniq
    return if ids.empty?

    permitted = writable_accounts.where(id: ids).count
    deny_write unless permitted == ids.size
  end

  def require_writable_report_group
    return if @report_group.nil?
    deny_write unless writable_report_groups.exists?(@report_group.id)
  end

  # @entity is already set (and already proved accessible) by the caller.
  def require_writable_entity
    return if @entity.nil?
    deny_write unless current_admin.writable_entity_ids.include?(@entity.id)
  end

  # These guards run on the form GETs as well as on the writes they protect —
  # new_deposit is a WRITE_ACTION. For the demo, opening the form is looking;
  # the POST that follows is still refused here, because demo_may_look? is false
  # for anything that is not a GET.
  def deny_write
    return if demo_may_look?

    deny_access(t("access.read_only_deny"), dashboard_path)
  end

  def writable_accounts
    @writable_accounts ||= current_admin.writable_accounts
  end
  def writable_journal_entries
    @writable_journal_entries ||= current_admin.writable_journal_entries
  end
  def writable_report_groups
    @writable_report_groups ||= current_admin.writable_report_groups
  end
  def writable_reports
    @writable_reports ||= current_admin.writable_reports
  end
  def writable_receipts
    @writable_receipts ||= current_admin.writable_receipts
  end
  def writable_entity_codes
    @writable_entity_codes ||= current_admin.writable_entity_codes
  end
  # An entry the admin has emptied out — every editable posting marked for
  # destruction, leaving only the invisible, auto-calculated balance line.
  # Saving would just error on "must balance"; they mean delete this entry. Pass
  # the bank account id on a bank entry, whose line is not an editable row; omit
  # it for a pure journal entry.
  def entry_emptied?(journal_entry, balance_account_id: nil)
    journal_entry.postings.none? do |p|
      !p.marked_for_destruction? && p.account_id != balance_account_id
    end
  end

  def load_form_data(account_types: nil)
    base  = accessible_accounts.active.leaf_accounts.order(:code)
    scope = account_types ? base.where(account_type: account_types) : base
    @account_options = build_account_options(scope)
    # The cross-entity modal always needs ALL types (personal gift, equity
    # capital, income/expense leg) even when the form restricts @account_options
    # — a bank entry limits to income/expense/personal, which would hide equity.
    @cross_entity_account_options = account_types ? build_account_options(base) : @account_options
    # Entity code → name, so the cross-entity modal's intro can name the
    # businesses.
    @cross_entity_entity_names = accessible_entities.pluck(:code, :name).to_h
    # Consolidation-group key of the account a bank entry is fixed to; the
    # cross-entity trigger compares a chosen account's group against it. Only
    # the bank-entry forms have a fixed account, so this is nil everywhere else.
    @home_group_key = @account && Entity.group_key_for_codes([@account.entity_code])[@account.entity_code]
    # The FX calculator converts money that EXISTS — see #report_currencies.
    @currencies = report_currencies
  end

  # Builds [label, id, data-attrs] select options, including the cross-entity
  # trigger attributes data-entity, data-group and data-type. See
  # Entity.group_key_for_codes.
  def build_account_options(scope)
    accounts     = scope.pluck(:id, :code, :name, :account_type, :currency, :deduction_percentage)
    entity_codes = accounts.map { |_id, code, *| code[1, 2] }.uniq
    group_keys   = Entity.group_key_for_codes(entity_codes)

    accounts.map { |id, code, name, _type, currency, deduction_pct|
      entity_code = code[1, 2]
      attrs = {
        'data-currency' => currency,
        'data-entity'   => entity_code,
        'data-group'    => group_keys[entity_code],
        'data-type'     => AccountCoding::ACCOUNT_TYPES[code[0].to_i]
      }
      attrs['data-deduction-pct'] = deduction_pct if deduction_pct
      ["#{code} - #{name}", id, attrs]
    }
  end

  def stream_csv_from_array(filename:, headers:, data:)
    stream_csv_response(filename) do |yielder|
      yielder << headers.to_csv
      data.each { |row| yielder << row.to_csv }
    end
  end
  def stream_csv_response(filename, &block)
    headers["Content-Type"] = "text/csv"
    headers["Content-Disposition"] = "attachment; filename=\"#{filename}\""
    headers["X-Accel-Buffering"] = "no"

    self.response_body = Enumerator.new(&block)
  end

  # Memoizes the relation object, not loaded results — SQL still fires on each
  # .find/.where/.pluck. Caching the full result set would load every accessible
  # account into Ruby memory on every request.
  def accessible_entity_ids
    @accessible_entity_ids ||= current_admin.accessible_entity_ids
  end
  def available_currencies
    CurrencyConfig.available
  end
  def accessible_accounts
    @accessible_accounts ||= current_admin.accessible_accounts
  end

  # The currencies worth CONVERTING INTO, a much shorter list than the ones the
  # app supports. available_currencies is every active currency, which is right
  # in the two places a currency ARRIVES — the account form and the exchange
  # rate form. Everywhere else you are working with money that already exists,
  # and the full list is noise: with twenty-five currencies the report dropdown
  # is fifty options, because it is currency × source.
  #
  # Two parts. What THIS ADMIN's accounts are actually kept in, scoped so one
  # business's euros do not drag in another's francs. And the BASE currency of
  # every configured source — a fixed handful that never grows with the currency
  # list, and the reason a GBP/CHF business can still read its report in euros.
  # Not a view about which currencies matter: a fact about which feeds exist, so
  # every option offered is one the app can actually convert into.
  def report_currencies
    @report_currencies ||= begin
      used  = Currency.used_codes(scope: accessible_accounts)
      bases = RateSourceConfig.bases.values.to_set

      available_currencies.select { |c| used.include?(c) || bases.include?(c) }
    end
  end
  def accessible_entities
    @accessible_entities ||= current_admin.accessible_entities
  end
  # NARROWER than accessible_entities, and the difference is the point: an admin
  # may READ an entity they may not upload a receipt to. This is the list
  # ReceiptsController#authorize_receipt_target actually enforces, so it is the
  # only correct one to OFFER in a receipt form — the wider one puts entities in
  # the picker that the server then refuses.
  #
  # Lives here rather than in ReceiptsController because the upload modal is
  # rendered from the dashboard and the entry forms as well, neither of which
  # goes through that controller.
  def entities_for_receipt_upload
    @entities_for_receipt_upload ||=
      accessible_entities.where(id: current_admin.upload_entity_ids).order(:code)
  end
  def accessible_journal_entries
    @accessible_journal_entries ||= current_admin.accessible_journal_entries
  end
  def accessible_postings
    @accessible_postings ||= current_admin.accessible_postings
  end
  def accessible_receipts
    @accessible_receipts ||= current_admin.accessible_receipts
  end
  def accessible_report_groups
    @accessible_report_groups ||= current_admin.accessible_report_groups
  end
  def accessible_reports
    @accessible_reports ||= current_admin.accessible_reports
  end
  def current_admin_entity_codes
    current_admin&.entity_codes || []
  end
  # The "closed up to" date for one entity, out of a table built once per
  # request for every entity this admin can see — _overview renders inside a
  # loop over entities, and asking FiscalPeriod per entity was one MAX-with-join
  # each. Nil means never closed.
  def last_closed_on(entity)
    @last_closed_by_code ||=
      FiscalPeriod.last_closed_on_by_code(accessible_entities.pluck(:code))
    @last_closed_by_code[entity.code]
  end

  # Up to ARCHIVE_CAP entries for the dashboard's Downloads row, newest first,
  # plus whether more exist. Anything past the cap lives on reports_path instead
  # of inline, so a decade-old entity does not grow an ever-wider row of dated
  # buttons.
  ARCHIVE_CAP = 4

  # Excludes today: the row's own "current date" button already covers it, and
  # generating twice in one day overwrites the same file — so without this, one
  # click made it appear twice.
  def recent_archives(entity)
    entries = Archives::Storage.list(Archives::Storage.scope_key_for(entity))
                                .reject { |e| e.end_date == Date.current }
    { entries: entries.first(ARCHIVE_CAP), more: entries.size > ARCHIVE_CAP }
  end
  # The admin's stated preference wins. Blank means "work it out from my
  # accounts": at login the app picks whichever currency most of their balance-
  # sheet accounts use.
  def default_display_currency
    current_admin&.preferred_currency.presence || session[:default_currency] || 'EUR'
  end
  def multi_entity_admin?
    current_admin_entity_codes.size > 1
  end
  def upload_receipts_only?
    @_upload_receipts_only ||= current_admin.upload_receipts_only?
  end
  def read_only_admin?
    @_read_only ||= current_admin.read_only?
  end
  def can_upload_receipts?
    @_can_upload ||= current_admin.sudo? || current_admin.admin_entities.with_receipt_access.exists?
  end
  # writable_entity_codes is the same question, memoised for the request —
  # _overview asks this once per entity while looping over them.
  def can_edit_for_entity?(entity_code)
    writable_entity_codes.include?(entity_code)
  end
  
end
