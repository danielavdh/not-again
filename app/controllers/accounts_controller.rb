# frozen_string_literal: true

class AccountsController < BaseController
  include CrossEntityJournalEntries
  before_action :set_account, only: [
    :show, :edit, :update, :destroy, :ledger, :balance_at,
    :quick_map_tax, :save_deduction_percentage,
    :new_deposit, :create_deposit, :edit_deposit, :update_deposit, :copy_deposit,
    :new_withdrawal, :create_withdrawal, :edit_withdrawal, :update_withdrawal, :copy_withdrawal,
    :new_transfer, :create_transfer, :edit_transfer, :update_transfer, :copy_transfer]

  # Everything that changes something, or offers a form that will. The account
  # itself must be writable, and so must every account a submitted posting
  # points at — including a transfer's far end and a cross-entity leg.
  WRITE_ACTIONS = [
    :edit, :update, :destroy, :quick_map_tax, :save_deduction_percentage,
    :new_deposit, :create_deposit, :edit_deposit, :update_deposit, :copy_deposit,
    :new_withdrawal, :create_withdrawal, :edit_withdrawal, :update_withdrawal, :copy_withdrawal,
    :new_transfer, :create_transfer, :edit_transfer, :update_transfer, :copy_transfer
  ].freeze
  SUBMIT_ACTIONS = [
    :create_deposit, :update_deposit, :create_withdrawal, :update_withdrawal,
    :create_transfer, :update_transfer
  ].freeze

  before_action :require_writable_account,            only: WRITE_ACTIONS
  before_action :require_writable_submitted_accounts, only: SUBMIT_ACTIONS

  def index
    # collects the parents
    scope = accessible_accounts.includes(:parent).order(:code)
    # collects the filter(ed)
    if params[:filter].present?
      filter = ActiveRecord::Base.sanitize_sql_like(params[:filter].strip)
      scope = scope.where("code ILIKE ? OR name ILIKE ?", "#{filter}%", "%#{filter}%")
    end
    respond_to do |format|
      format.html do
        if params[:filter].present?
          @accounts = scope.limit(100).to_a
          @pagy = nil
        else
          @pagy, @accounts = pagy(accessible_accounts.order(:code), paginator: :countish, limit: 80)
        end
        load_account_data
      end
      format.json do
        # For AJAX filter requests
        @accounts = scope.limit(100).to_a
        load_account_data
        
        render json: {
          html: render_to_string(
          partial: 'accounts/accounts_table_rows',
          formats: [:html],
          locals: { accounts: @accounts, balances: @balances, parent_balances: @parent_balances, accounts_with_children: @accounts_with_children, undeletable_ids: @undeletable_account_ids })
        }
    end
      format.csv { export_csv }
    end
  end

  def show
    @balance = @account.balance
  end

  def new
    @account = Account.new(account_type: params[:fixed_type].presence,
                                currency: params[:fixed_currency].presence)
    # Cross-entity "add account on the fly": the entity and type are already
    # decided by what the user was doing, so the first three digits are fixed.
    # Seeded on the record rather than passed to the field as a value, so the
    # ordinary new/edit form needs no branch at all.
    @account.code = params[:code_prefix] if params[:cross_entity].present?
    load_parent_options(code_prefix: params[:cross_entity].present? ? params[:code_prefix] : nil)
    load_tax_category_options
    # Cross-entity "add account on the fly" (#6): render just the form for the
    # modal.
    render partial: "form", layout: false, locals: cross_entity_form_locals if params[:cross_entity].present?
  end

  def create
    explode_tax_combined!
    @account = Account.new(account_params)
    # The model re-checks this (Account#entity_code_matches_creator), so a
    # controller that forgets cannot open the door again.
    @account.creating_admin = current_admin
    ok = @account.save

    if ok
      respond_to do |format|
        format.json { render json: cross_entity_account_json(@account), status: :created }
        format.html { redirect_to accounts_path, notice: t("accounts.created") }
      end
    else
      respond_to do |format|
        format.json { render json: { errors: @account.errors.full_messages }, status: :unprocessable_entity }
        format.html do
          load_parent_options
          load_tax_category_options
          render :new, status: :unprocessable_entity
        end
      end
    end
  end

  def edit
    load_parent_options
    load_tax_category_options
  end

  def update
    explode_tax_combined!
    if @account.update(account_params)
      redirect_to accounts_path, notice: t("accounts.updated")
    else
      load_parent_options
      load_tax_category_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @account.has_postings?
      redirect_to accounts_path, alert: t("accounts.cannot_delete")
      return
    end
    if @account.destroy
      redirect_to accounts_path, notice: t("accounts.deleted")
    else
      redirect_to accounts_path, alert: @account.errors.full_messages.join(', ')
    end
  end

  # Account history/ledger with option to copy entries
  def ledger
    @start_date = params[:start_date].presence&.to_date
    @end_date   = params[:end_date]&.to_date
    base_scope  = Posting.ledger_base_scope(@account.id, start_date: @start_date, end_date: @end_date)

    respond_to do |format|
      format.html do
        @pagy, paginated = pagy(base_scope, limit: 25)
        @ledger_data = Posting.ledger_data_from_scope(paginated, @account)
        @show_balance = @account.balance_account?
        if @show_balance
          @running_balances = calculate_running_balances(@account, @ledger_data, @start_date, @end_date, @pagy)
        end
      end
      format.csv { export_ledger_csv }
    end
  end

  def new_deposit
    @journal_entry = JournalEntry.new(entry_date: Date.current)
    @journal_entry.postings.build(entry_type: :credit) # Counter accounts (income/other)
    @entry_type = 'deposit'
    load_form_data(account_types: [:income, :expense, :personal])
    render :bank_entry
  end
  def create_deposit
    @entry_type = 'deposit'
    result = create_bank_entry(:deposit)

    if result[:success]
      notice_key = if @account.equity?
        result[:type] == :deposit ? "drawing_created" : "contribution_created"
      else
        result[:type] == :deposit ? "deposit_created" : "withdrawal_created"
      end
      base   = t("accounts.#{notice_key}")
      notice = [base, refresh_affected_closing_entry(result[:journal_entry])].compact.join(" ")
      redirect_to ledger_account_path(@account), notice: notice
    else
      @journal_entry = result[:journal_entry]
      @journal_entry.postings.build(entry_type: :credit) if @journal_entry.postings.empty?
      load_form_data(account_types: [:income, :expense, :personal])
      @cross_entity_rerender = cross_entity_rerender_entries
      render :bank_entry, status: :unprocessable_entity
    end
  end
  def edit_deposit
    @journal_entry = accessible_journal_entries.includes(postings: :receipts).find(params[:journal_entry_id])
    return if redirect_cross_entity_counterpart_to_origin(@journal_entry) # JE₂ → JE₁'s edit
    @entry_type = 'deposit'
    load_form_data(account_types: [:income, :expense, :personal])
    @cross_entity_persisted = cross_entity_persisted_entries(@journal_entry)
    render :bank_entry
  end
  def update_deposit
    @entry_type = 'deposit'
    @journal_entry = accessible_journal_entries.includes(postings: :receipts).find(params[:journal_entry_id])
    @journal_entry.assign_attributes(bank_entry_params)
    recalculate_bank_posting

    if entry_emptied?(@journal_entry, balance_account_id: @account.id)
      @journal_entry.destroy # all visible postings marked → delete the entry
      return redirect_or_close_popup ledger_account_path(@account), notice: t("journal_entries.deleted")
    end
    if save_with_cross_entity_entries(@journal_entry)
      base   = t("accounts.#{@account.equity? ? 'drawing_updated' : 'deposit_updated'}")
      notice = [base, refresh_affected_closing_entry(@journal_entry)].compact.join(" ")
      redirect_or_close_popup ledger_account_path(@account), notice: notice
    else
      load_form_data(account_types: [:income, :expense, :personal])
      @cross_entity_rerender = cross_entity_rerender_entries
      render :bank_entry, status: :unprocessable_entity
    end
  end
  def copy_deposit
    original = accessible_journal_entries.find(params[:journal_entry_id])
    return if redirect_cross_entity_counterpart_to_copy(original) # copy JE₂ → copy JE₁
    @journal_entry = JournalEntry.new(
      entry_date: Date.current,
      memo: original.memo,
      journal_reference: original.journal_reference
    )
    pair_id_map = {}
    copy = build_cross_entity_copy(original) # fresh links + JE₂′ mirror (#8)
    original.postings.where.not(account_id: @account.id).each do |p|
      @journal_entry.postings.build(
        account_id: p.account_id,
        entry_type: p.entry_type,
        amount: p.amount,
        currency: p.currency,
        description: p.description,
        reference: p.reference,
        deduction_percentage: p.deduction_percentage,
        deduction_pair_id: remap_pair_id(p.deduction_pair_id, pair_id_map),
        cross_entity_link_id: (p.cross_entity_link_id.present? ? copy[:link_remap][p.cross_entity_link_id] : nil)
      )
    end
    @cross_entity_rerender = copy[:rerender]

    @entry_type = 'deposit'
    load_form_data(account_types: [:income, :expense, :personal])
    flash.now[:notice] = t("crud.is_copy")
    render :bank_entry
  end

  def new_withdrawal
    @journal_entry = JournalEntry.new(entry_date: Date.current)
    @journal_entry.postings.build(entry_type: :debit) # Counter accounts (expenses/other)
    @entry_type = 'withdrawal'
    load_form_data(account_types: [:income, :expense, :personal])
    render :bank_entry
  end
  def create_withdrawal
    @entry_type = 'withdrawal'
    result = create_bank_entry(:withdrawal)

    if result[:success]
      notice_key = if @account.equity?
        result[:type] == :withdrawal ? "contribution_created" : "drawing_created"
      else
        result[:type] == :withdrawal ? "withdrawal_created" : "deposit_created"
      end
      base   = t("accounts.#{notice_key}")
      notice = [base, refresh_affected_closing_entry(result[:journal_entry])].compact.join(" ")
      redirect_to ledger_account_path(@account), notice: notice
    else
      @journal_entry = result[:journal_entry]
      @journal_entry.postings.build(entry_type: :debit) if @journal_entry.postings.empty?
      load_form_data(account_types: [:income, :expense, :personal])
      @cross_entity_rerender = cross_entity_rerender_entries
      render :bank_entry, status: :unprocessable_entity
    end
  end
  def edit_withdrawal
    @journal_entry = accessible_journal_entries.includes(postings: :receipts).find(params[:journal_entry_id])
    return if redirect_cross_entity_counterpart_to_origin(@journal_entry) # JE₂ → JE₁'s edit
    @entry_type = 'withdrawal'
    load_form_data(account_types: [:income, :expense, :personal])
    @cross_entity_persisted = cross_entity_persisted_entries(@journal_entry)
    render :bank_entry
  end
  def update_withdrawal
    @entry_type = 'withdrawal'
    @journal_entry = accessible_journal_entries.includes(postings: :receipts).find(params[:journal_entry_id])
    
    @journal_entry.assign_attributes(bank_entry_params)
    recalculate_bank_posting

    if entry_emptied?(@journal_entry, balance_account_id: @account.id)
      @journal_entry.destroy # all visible postings marked → delete the entry
      return redirect_or_close_popup ledger_account_path(@account), notice: t("journal_entries.deleted")
    end
    if save_with_cross_entity_entries(@journal_entry)
      base   = t("accounts.#{@account.equity? ? 'contribution_updated' : 'withdrawal_updated'}")
      notice = [base, refresh_affected_closing_entry(@journal_entry)].compact.join(" ")
      redirect_or_close_popup ledger_account_path(@account), notice: notice
    else
      load_form_data(account_types: [:income, :expense, :personal])
      @cross_entity_rerender = cross_entity_rerender_entries
      render :bank_entry, status: :unprocessable_entity
    end
  end
  def copy_withdrawal
    original = accessible_journal_entries.find(params[:journal_entry_id])
    return if redirect_cross_entity_counterpart_to_copy(original) # copy JE₂ → copy JE₁
    @journal_entry = JournalEntry.new(
      entry_date: Date.current,
      memo: original.memo,
      journal_reference: original.journal_reference
    )
    pair_id_map = {}
    copy = build_cross_entity_copy(original) # fresh links + JE₂′ mirror (#8)
    original.postings.where.not(account_id: @account.id).each do |p|
      @journal_entry.postings.build(
        account_id: p.account_id,
        entry_type: p.entry_type,
        amount: p.amount,
        currency: p.currency,
        description: p.description,
        reference: p.reference,
        deduction_percentage: p.deduction_percentage,
        deduction_pair_id: remap_pair_id(p.deduction_pair_id, pair_id_map),
        cross_entity_link_id: (p.cross_entity_link_id.present? ? copy[:link_remap][p.cross_entity_link_id] : nil)
      )
    end
    @cross_entity_rerender = copy[:rerender]

    @entry_type = 'withdrawal'
    load_form_data(account_types: [:income, :expense, :personal])
    flash.now[:notice] = t("crud.is_copy")
    render :bank_entry
  end

  def new_transfer
    @journal_entry = JournalEntry.new(entry_date: Date.current)
    @journal_entry.from_account_id = @account.id
    @entry_type = 'transfer'
    load_transfer_data
    render :transfer_entry
  end
  def create_transfer
    @entry_type = 'transfer'
    @journal_entry = JournalEntry.new(transfer_entry_params)
    
    from_id = params.dig(:journal_entry, :from_account_id)
    to_id = params.dig(:journal_entry, :to_account_id)

    if from_id.blank? || to_id.blank?
      @journal_entry.errors.add(:base, "Both accounts are required for a transfer")
      load_transfer_data
      render :transfer_entry, status: :unprocessable_entity
      return
    end

    from_currency, to_currency = fetch_transfer_currencies(
      @journal_entry.from_account_id,
      @journal_entry.to_account_id
    )

    # For cross-currency: use target_amount; for same currency: use
    # source_amount
    source_amount = @journal_entry.transfer_amount
    target_amount = if from_currency != to_currency && @journal_entry.target_amount.present?
                      @journal_entry.target_amount
                    else
                      source_amount
                    end
    
    @journal_entry.postings.build(
      account_id: @journal_entry.from_account_id,
      entry_type: :credit,
      amount: source_amount,
      currency: from_currency
    )
    @journal_entry.postings.build(
      account_id: @journal_entry.to_account_id,
      entry_type: :debit,
      amount: target_amount,
      currency: to_currency
    )
    
    if @journal_entry.save
      base   = t("accounts.transfer_created")
      notice = [base, refresh_affected_closing_entry(@journal_entry)].compact.join(" ")
      redirect_to ledger_account_path(@account), notice: notice
    else
      load_transfer_data
      render :transfer_entry, status: :unprocessable_entity
    end
  end
  def edit_transfer
    @journal_entry = accessible_journal_entries.includes(:postings).find(params[:journal_entry_id])
    @entry_type = 'transfer'
    credit_posting = @journal_entry.postings.find(&:credit?)
    debit_posting = @journal_entry.postings.find(&:debit?)
    @journal_entry.from_account_id = credit_posting&.account_id
    @journal_entry.to_account_id = debit_posting&.account_id
    @journal_entry.transfer_amount = credit_posting&.amount
    @journal_entry.target_amount = debit_posting&.amount
      
    load_transfer_data
    render :transfer_entry
  end
  def update_transfer
    @entry_type = 'transfer'
    @journal_entry = accessible_journal_entries.includes(:postings).find(params[:journal_entry_id])
    @journal_entry.assign_attributes(transfer_entry_params)
    
    from_currency, to_currency = fetch_transfer_currencies(
      @journal_entry.from_account_id,
      @journal_entry.to_account_id
    )
    source_amount = @journal_entry.transfer_amount
    target_amount = if from_currency != to_currency && @journal_entry.target_amount.present?
                      @journal_entry.target_amount
                    else
                      source_amount
                    end

    credit_posting = @journal_entry.postings.find(&:credit?) || @journal_entry.postings.build(entry_type: :credit)
    debit_posting = @journal_entry.postings.find(&:debit?) || @journal_entry.postings.build(entry_type: :debit)
    credit_posting.assign_attributes(
      account_id: @journal_entry.from_account_id,
      amount: source_amount,
      currency: from_currency
    )
    debit_posting.assign_attributes(
      account_id: @journal_entry.to_account_id,
      amount: target_amount,
      currency: to_currency
    )
    
    if @journal_entry.save
      base   = t("accounts.transfer_updated")
      notice = [base, refresh_affected_closing_entry(@journal_entry)].compact.join(" ")
      redirect_or_close_popup ledger_account_path(@account), notice: notice
    else
      load_transfer_data
      render :transfer_entry, status: :unprocessable_entity
    end
  end
  def copy_transfer
    original = accessible_journal_entries.find(params[:journal_entry_id])

    # More than a plain two-leg transfer — an entry with three or more balance
    # accounts and no nominal leg, allowed on purpose for a pro building a
    # multi-account entry by hand. credit_posting/debit_posting below only ever
    # grab the FIRST of each and silently drop the rest, so anything past a true
    # two-leg entry goes to the general duplicate instead, which copies every
    # posting.
    if original.postings.size > 2
      redirect_to duplicate_journal_entry_path(original)
      return
    end

    @journal_entry = JournalEntry.new(
      entry_date: Date.current,
      memo: original.memo,
      journal_reference: original.journal_reference
    )
    credit_posting = original.postings.find(&:credit?)
    debit_posting = original.postings.find(&:debit?)
    @journal_entry.from_account_id = credit_posting&.account_id
    @journal_entry.to_account_id = debit_posting&.account_id
    @journal_entry.transfer_amount = credit_posting&.amount
    @journal_entry.target_amount = debit_posting&.amount

    @entry_type = 'transfer'
    load_transfer_data
    flash.now[:notice] = t("crud.is_copy")
    render :transfer_entry
  end
  
  # Called by the dashboard tax-mapping widget: saves scheme+key on a single
  # account.
  def balance_at
    date = Date.parse(params[:date])
    render json: { balance_cents: @account.balance(end_date: date).to_i, currency: @account.currency }
  rescue ArgumentError, TypeError
    render json: { error: 'invalid date' }, status: :bad_request
  end

  def save_deduction_percentage
    pct = params[:deduction_percentage].to_i
    if (1..99).include?(pct) && @account.update(deduction_percentage: pct)
      render json: { ok: true }
    else
      render json: { error: 'invalid' }, status: :unprocessable_entity
    end
  end

  # Assign, re-assign, or (with a blank category) unassign. Blank is a real
  # instruction from the tax report page's × button — it releases the account so
  # another scheme may claim it — not the "nothing chosen" case, which the
  # caller never sends.
  def quick_map_tax
    combined = params[:tax_category_combined].to_s
    scheme, key = combined.blank? ? [ nil, nil ] : combined.split("::", 2)
    if @account.update(tax_scheme: scheme, tax_category_key: key)
      render json: { ok: true }
    else
      render json: { error: @account.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # fetch call to fill parent_id select
  def parents_for_type
    accounts = accessible_accounts
                    .by_type(params[:type].to_i)
                    .where(parent_id: nil)
                    .ordered
    render json: accounts.select(:id, :name, :code, :currency)
  end

private

  # set_account override in base controller

  def load_account_data
    @account_ids = @accounts.map(&:id)
    @balances = Account.balances_for(@account_ids)
    @accounts_with_children = accessible_accounts.where(parent_id: @account_ids).distinct.pluck(:parent_id).to_set
    @undeletable_account_ids = undeletable_account_ids(@account_ids)
    @parent_balances = calculate_parent_balances_from_db(@accounts_with_children.to_a)
  end

  # Ids of the accounts on this page that must NOT be offered for deletion —
  # they have postings of their own, or a child that has.
  #
  # Account#deletable? answers this per account with two exists? queries, and
  # the table asks twice per row (the confirm text, then the button). On a
  # 16-account fixture that measured 29 of the page's 42 queries, and it grows
  # with the chart of accounts. Two queries for the whole page instead, ids
  # only.
  def undeletable_account_ids(ids)
    return Set.new if ids.blank?

    own = Posting.where(account_id: ids).distinct.pluck(:account_id)
    via_children = Posting.joins(:account)
                               .where(accounts: { parent_id: ids })
                               .distinct
                               .pluck("accounts.parent_id")
    (own + via_children).to_set
  end

  def calculate_parent_balances_from_db(parent_ids)
    return {} if parent_ids.empty?

    child_data = accessible_accounts.where(parent_id: parent_ids).pluck(:id, :parent_id)
    return {} if child_data.empty?

    child_balances = Account.balances_for(child_data.map(&:first))

    child_data.each_with_object(Hash.new(0)) do |(child_id, parent_id), totals|
      totals[parent_id] += child_balances[child_id] || 0
    end
  end

  # Used by export_csv only (all accounts already loaded, no pagination
  # concern).
  def calculate_parent_balances(accounts, balances)
    children_by_parent = accounts.group_by(&:parent_id).except(nil)
    children_by_parent.transform_values do |children|
      children.sum { |child| balances[child.id] || 0 }
    end
  end

  def account_params
      params.require(:account).permit(
      :code, :name, :description, :account_type, :currency, :parent_id, :active,
      :tax_scheme, :tax_category_key)
  end

  # Locals for the cross-entity add-account form (#6): entity+type are fixed
  # (encoded in code_prefix), currency fixed, name gets a suggested placeholder.
  def cross_entity_form_locals
    {
      account: @account,
      fixed_type: params[:fixed_type],
      fixed_currency: params[:fixed_currency],
      code_prefix: params[:code_prefix],
      name_placeholder: t("entities.cross_entity.#{params[:fixed_type] == 'personal' ? 'gift' : 'capital'}_name_placeholder")
    }
  end

  # Shape mirrors build_account_options' data-attrs so the JS can inject a full
  # option into the modal's TomSelect and it survives re-filtering.
  def cross_entity_account_json(account)
    {
      id:       account.id,
      value:    account.id,
      label:    "#{account.code} - #{account.name}",
      entity:   account.entity_code,
      group:    Entity.group_key_for_codes([account.entity_code])[account.entity_code],
      currency: account.currency.to_s,
      type:     account.account_type
    }
  end
  def bank_entry_params
    # POSTING_PARAMS (from CrossEntityJournalEntries) incl. cross_entity_link_id
    # so a bank entry's 601 gift posting can carry its link.
    params.require(:journal_entry).permit(
      :entry_date, :memo, :journal_reference,
      postings_attributes: POSTING_PARAMS
    )
  end
  def transfer_entry_params
    params.require(:journal_entry).permit(
      :entry_date, :memo, :journal_reference, 
      :from_account_id, :to_account_id, 
      :transfer_amount, :transfer_amount_display,
      :target_amount, :target_amount_display
    )
  end

  def export_csv
    scope = accessible_accounts.order(:code)
    if params[:filter].present?
      filter = ActiveRecord::Base.sanitize_sql_like(params[:filter].strip)
      scope = scope.where("code ILIKE ? OR name ILIKE ?", "#{filter}%", "%#{filter}%")
    end
    accounts = scope.to_a
    account_ids = accounts.map(&:id)
    balances = Account.balances_for(account_ids)
    parent_balances = calculate_parent_balances(accounts, balances)

    csv_data = accounts.map do |account|
      balance = if account.balance_account?
                  if parent_balances[account.id]
                    helpers.format_amount_csv(parent_balances[account.id])
                  else
                    helpers.format_amount_csv(balances[account.id] || 0)
                  end
                else
                  ''
                end
      [account.code, account.name, t("jargon.#{account.account_type}"), account.currency, balance]
    end

    stream_csv_from_array(
      filename: "accounts_#{Date.current}.csv",
      headers: [t("attrs.code"), t("attrs.name"), t("attrs.type"), t("jargon.currency"), t("jargon.balance")],
      data: csv_data
    )
  end    
  
  def export_ledger_csv
    # Get all data without pagination for CSV
    all_data = Posting.ledger_data_with_counter_accounts(@account.id, start_date: @start_date, end_date: @end_date)

    show_balance = @account.balance_account?

    if show_balance
      # Calculate running balances for all entries
      opening = @start_date ? @account.balance(end_date: @start_date - 1.day) : 0
      running = opening
  
      # Process in reverse (oldest first) to calculate balances
      balances_map = {}
      all_data.reverse_each do |row|
        posting_id = row.posting_id
        is_debit   = row.debit?
        amount     = row.amount

        if @account.debit_normal?
          running += is_debit ? amount : -amount
        else
          running += is_debit ? -amount : amount
        end
        balances_map[posting_id] = running
      end
    end

    headers = ['Date', 'Type', 'Counter Account', 'Description', 'Debit', 'Credit', 'Currency']
    headers << 'Balance' if show_balance

    csv_data = all_data.map do |row|
      row_data = [
        format_date_csv(row.date),
        row.transaction_type,
        helpers.format_counter_account_text(row.counter_accounts),
        row.description || row.memo,
        row.debit? ? helpers.format_amount_csv(row.amount) : '',
        row.debit? ? '' : helpers.format_amount_csv(row.amount),
        row.display_currency
      ]
      row_data << helpers.format_amount_csv(balances_map[row.posting_id]) if show_balance
      row_data
    end

    stream_csv_from_array(
      filename: "ledger_#{@account.code}_#{Date.current}.csv",
      headers: headers,
      data: csv_data
    )
  end    
  
  def format_date_csv(date)
    date&.strftime('%Y-%m-%d')
  end    

  def load_tax_category_options
    @tax_category_options = []
    return unless @account&.tax_taggable?

    # The ACCOUNT's entity, not the admin's primary one: digits 2-3 of the code
    # say whose account this is. Reading the admin's default meant an account
    # belonging to any other entity offered no categories at all, so its field
    # never appeared.
    entity  = Entity.find_by(code: @account.entity_code)
    schemes = Array(entity&.tax_schemes)
    return if schemes.empty?

    # No country filter: a scheme slug is unique across countries, so the scheme
    # alone identifies its catalogue rows. That is what lets an entity carry
    # schemes from more than one country, each keeping its own categories.
    @tax_category_options = TaxCategory.grouped_options(schemes)
    return if @tax_category_options.empty?

    # Surface retired categories so the dropdown shows the current value even if
    # it's no longer in the catalogue.
    latest_year = TaxCategory.where(scheme: schemes).maximum(:tax_year)
    current     = TaxCategory.where(scheme: schemes, tax_year: latest_year)
    if @account.tax_category_key.present? &&
       current.none? { |r| r.key == @account.tax_category_key && r.scheme == @account.tax_scheme }
      retired_value = "#{@account.tax_scheme}::#{@account.tax_category_key}"
      retired_label = "#{@account.tax_category_key.humanize} (retired)"
      @tax_category_options.unshift(["Retired", [[retired_label, retired_value]]])
    end
  end
  def explode_tax_combined!
    return unless params[:account].key?(:tax_category_combined)
    combined = params[:account].delete(:tax_category_combined)
    if combined.blank?
      params[:account][:tax_scheme] = nil
      params[:account][:tax_category_key] = nil
    else
      scheme, key = combined.split("::", 2)
      params[:account][:tax_scheme] = scheme
      params[:account][:tax_category_key] = key
    end
  end
  
  def load_parent_options(code_prefix: nil)
    parents = accessible_accounts.ordered
      .where(parent_id: nil)
      .where.not(id: @account&.id)
    # Cross-entity add-account: only parents in the same type+entity (first 3
    # digits).
    parents = parents.where("code LIKE ?", "#{code_prefix}%") if code_prefix.present?
    @parent_options = parents.pluck(:code, :name, :id, :currency).map do |code, name, id, currency|
      ["#{code} - #{name}", id, { 'data-currency' => currency.to_s }]
    end
  end

  def load_transfer_data
    load_form_data(account_types: [:asset, :liability, :equity])
    @transfer_account_currencies = @account_options.each_with_object({}) do |(_, id, attrs), hash|
      hash[id] = attrs['data-currency']
    end
  end
  
  def fetch_transfer_currencies(from_id, to_id)
    currencies = accessible_accounts.where(id: [from_id, to_id].compact)
                             .pluck(:id, :currency)
                             .to_h
    # Balance accounts MUST have currency - if nil, there's a data error
    from_currency = currencies[from_id.to_i]
    to_currency = currencies[to_id.to_i]

    raise "Balance account #{from_id} missing currency" if from_currency.nil?
    raise "Balance account #{to_id} missing currency" if to_currency.nil?

    [from_currency, to_currency]
  end
  
  def create_bank_entry(type)
    @journal_entry = JournalEntry.new(bank_entry_params)

    # Discard any bank account postings that came through form params on re-
    # submit after failure
    @journal_entry.postings.select { |p| p.account_id == @account.id }.each(&:mark_for_destruction)

    # Calculate net balance from counter account postings
    default_currency = @account.currency# || 'GBP'
    balance_by_currency = Hash.new(0)
    @journal_entry.postings.each do |posting|
      next if posting.marked_for_destruction?
      next if posting.amount.blank? || posting.amount == 0
      currency = posting.currency.presence || default_currency
      if posting.debit?
        balance_by_currency[currency] += posting.amount
      else
        balance_by_currency[currency] -= posting.amount
      end
    end
    
    # Check for negative totals and auto-convert entry type if needed
    balance_by_currency.each do |currency, balance|
      # For withdrawal: balance should be positive (net debit to expense
      # accounts)
      # For deposit: balance should be negative (net credit to income accounts)
      if type == :withdrawal && balance < 0
        # Negative withdrawal -> convert to deposit
        type = :deposit
      elsif type == :deposit && balance > 0
        # Negative deposit -> convert to withdrawal
        type = :withdrawal
      end
      
      # Add bank account posting (opposite side to balance the entry)
      if type == :withdrawal
        # Withdrawal: bank account is credited (money out)
        @journal_entry.postings.build(
          account_id: @account.id,
          entry_type: :credit,
          amount: balance.abs,
          currency: currency
        )
      else
        # Deposit: bank account is debited (money in)
        @journal_entry.postings.build(
          account_id: @account.id,
          entry_type: :debit,
          amount: balance.abs,
          currency: currency
        )
      end
    end
    
    if save_with_cross_entity_entries(@journal_entry)
      { success: true, journal_entry: @journal_entry, type: type }
    else
      { success: false, journal_entry: @journal_entry }
    end
  end
  
  def calculate_running_balances(account, ledger_data, start_date, end_date, pagy)
    return [] if ledger_data.empty?

    # current_balance is in CENTS
    current_balance = account.balance(end_date: end_date)

    if pagy.page > 1
      later_scope = Posting.ledger_base_scope(account.id, start_date: start_date, end_date: end_date)
                                .limit(pagy.offset)

      later_data = later_scope.pluck(:entry_type, :amount)
      later_adjustment = later_data.sum do |entry_type, amount|
        is_debit = (entry_type == "debit")
        if account.debit_normal?
          is_debit ? amount : -amount
        else
          is_debit ? -amount : amount
        end
      end

      current_balance -= later_adjustment  # both in cents, no division!
    end

    balances = []
    running = current_balance

    ledger_data.each do |row|
      balances << running  # return cents, view will format

      is_debit = row.debit?
      amount   = row.amount

      if account.debit_normal?
        running -= is_debit ? amount : -amount
      else
        running -= is_debit ? -amount : amount
      end
    end

    balances  # returns cents
  end
      
  def recalculate_bank_posting
    bank_posting = @journal_entry.postings.find { |p| p.account_id == @account.id }
    return unless bank_posting

    balance = 0
    @journal_entry.postings.each do |posting|
      next if posting.marked_for_destruction?
      next if posting.account_id == @account.id
      next if posting.amount.blank?
  
      # Handle negative amounts (before normalize_negative_amounts runs)
      amount = posting.amount
      is_debit = posting.debit?
  
      if amount < 0
        amount = amount.abs
        is_debit = !is_debit  # Flip the side
      end
  
      next if amount == 0
  
      balance += is_debit ? amount : -amount
    end

    bank_posting.amount = balance.abs
    bank_posting.entry_type = balance >= 0 ? :credit : :debit
  end
  
  def redirect_or_close_popup(path, notice:)
    if params[:popup].present?
      render 'reports/popup_saved', layout: 'accounts'
    else
      redirect_to path, notice: notice
    end
  end
end
