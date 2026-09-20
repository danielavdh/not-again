# frozen_string_literal: true

class JournalEntriesController < BaseController
  include CrossEntityJournalEntries
  before_action :set_journal_entry, only: [:show, :edit, :update, :destroy, :post, :unpost, :duplicate]
  # An entry may be READ wherever the admin has a link, but only changed where
  # that link says full_access — see Admin#writable_journal_entries.
  before_action :require_writable_journal_entry,      only: [:edit, :update, :destroy, :post, :unpost]
  before_action :require_writable_submitted_accounts, only: [:create, :update]

  def index
    @filtered_scope = filtered_journal_entries
    @pagy, @journal_entries = pagy(@filtered_scope, limit: 25)
    load_posting_display_data(@journal_entries.map(&:id))

    respond_to do |format|
      format.html
      format.json do
        render json: {
          html: render_to_string(
            partial: 'journal_entries/journal_entry_rows',
            formats: [:html],
            locals: {
              journal_entries: @journal_entries,
              balance_account: @balance_account,
              credit_sums: @credit_sums,
              credit_currency: @credit_currency,
              cross_entity_je_ids: @cross_entity_je_ids,
              app_owned_close_ids: @app_owned_close_ids
            }
          )
        }
      end
      format.csv { export_csv(@filtered_scope) }
    end
  end

  def show
    @journal_entry = accessible_journal_entries.includes(postings: [:account, :receipts]).find(params[:id])
    @sorted_postings = @journal_entry.postings.sort_by { |p| p.account&.code.to_s }
    @display_currency = @journal_entry.display_currency
    # The linked entry/entries on the OTHER side (symmetric: JE₁→JE₂(s),
    # JE₂→JE₁),
    # shown inline as a read-only mirror band (#7).
    if @journal_entry.cross_entity?
      @cross_entity_linked = @journal_entry.cross_entity_linked_entries
                                           .includes(postings: [:account, :receipts]).to_a
      codes = @cross_entity_linked.flat_map { |je| je.postings.filter_map { |p| p.account&.entity_code } }.uniq
      names = Entity.where(code: codes).pluck(:code, :name).to_h
      # What to call each linked entry's business, keyed by entry id — an entry
      # belongs to one entity, so this is one label each. Nil where the code is
      # unknown; the heading omits it.
      @linked_entity_label = @cross_entity_linked.to_h do |je|
        code = je.postings.filter_map { |p| p.account&.entity_code }.first
        [je.id, code && (names[code].presence || code)]
      end
    end
  end

  def new
    @journal_entry = JournalEntry.new(entry_date: Date.current)
    @journal_entry.postings.build(entry_type: :debit)
    @journal_entry.postings.build(entry_type: :credit)
    @entity = nil
    load_form_data
  end

  def create
    @journal_entry = JournalEntry.new(journal_entry_params)
    if save_with_cross_entity_entries(@journal_entry)
      redirect_to journal_entry_path(@journal_entry), notice: t("journal_entries.created")
    else
      while @journal_entry.postings.size < 2
        @journal_entry.postings.build(entry_type: :credit)
      end
      load_form_data
      @cross_entity_rerender = cross_entity_rerender_entries
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @journal_entry = accessible_journal_entries.includes(postings: [:receipts, :account]).find(params[:id])
    return if redirect_cross_entity_counterpart_to_origin(@journal_entry) # JE₂ → JE₁'s edit
    @journal_entry.postings.build if @journal_entry.postings.empty?
    @entity = nil
    load_form_data
    @cross_entity_persisted = cross_entity_persisted_entries(@journal_entry)
    # Only ever fires for a non-pro — see #duplicate.
    flash.now[:notice] = t("journal_entries.edit.beginner_warning") unless current_admin.full_access_pro?
  end

  def update
    @journal_entry.assign_attributes(journal_entry_params)
    if entry_emptied?(@journal_entry)
      @journal_entry.destroy # all postings marked → delete the entry (cascades a cross-entity JE₂ if the gift was among them)
      return redirect_to journal_entries_path, notice: t("journal_entries.deleted")
    end
    if save_with_cross_entity_entries(@journal_entry)
      redirect_to journal_entry_path(@journal_entry), notice: t("journal_entries.updated")
    else
      load_form_data
      @cross_entity_rerender = cross_entity_rerender_entries
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    back_path = params[:from] == 'ledger' && params[:account_id].present? ?
                ledger_account_path(params[:account_id]) :
                journal_entries_path
    if @journal_entry.posted?
      redirect_to back_path, alert: t("journal_entries.cannot_delete_posted")
    else
      # Cross-entity cascade is per-posting in the model
      # (Posting#handle_cross_entity_link_on_destroy): destroying a gift (601)
      # posting deletes its counterpart JE₂, whether alone on a form or as part
      # of this whole entry; destroying a capital (304) posting only severs the
      # link.
      @journal_entry.destroy
      redirect_to back_path, notice: t("journal_entries.deleted")
    end
  end

  def post
    if @journal_entry.post!
      # A cross-entity pair moves together: post/unpost cascades to the linked
      # entry/entries (both live or both draft), without touching the link
      # itself.
      @journal_entry.cross_entity_linked_entries.each(&:post!)
      base   = t("journal_entries.posted")
      notice = [base, refresh_affected_closing_entry(@journal_entry)].compact.join(" ")
      redirect_to journal_entry_path(@journal_entry, from: params[:from], account_id: params[:account_id]), notice: notice
    else
      redirect_to journal_entry_path(@journal_entry, from: params[:from], account_id: params[:account_id]), alert: t("journal_entries.cannot_post_unbalanced")
    end
  end

  def unpost
    @journal_entry.unpost!
    @journal_entry.cross_entity_linked_entries.each(&:unpost!) # keep the linked pair together
    base   = t("journal_entries.unposted")
    notice = [base, refresh_affected_closing_entry(@journal_entry)].compact.join(" ")
    redirect_to journal_entry_path(@journal_entry, from: params[:from], account_id: params[:account_id]), notice: notice
  end
  
  def duplicate
    return if redirect_cross_entity_counterpart_to_copy(@journal_entry) # copy JE₂ → copy JE₁
    @original = @journal_entry
    @journal_entry = @original.dup
    @journal_entry.entry_date = Date.current
    @journal_entry.posted = false
    # A copy is always an ordinary entry: carrying the closing flags over would
    # produce a second close for the same period, and a duplicated movement into
    # retained earnings.
    @journal_entry.closing_entry = false
    @journal_entry.period_start  = nil
    @journal_entry.period_end    = nil
    pair_id_map = {}
    copy = build_cross_entity_copy(@original) # fresh links + the JE₂′ mirror (#8)
    @original.postings.each do |p|
      attrs = p.attributes.except('id', 'created_at', 'updated_at', 'journal_entry_id')
      attrs['deduction_pair_id'] = remap_pair_id(attrs['deduction_pair_id'], pair_id_map)
      # Never copy the raw link — remap the gift to its FRESH link (or strip).
      attrs['cross_entity_link_id'] = copy[:link_remap][attrs['cross_entity_link_id']] if attrs['cross_entity_link_id'].present?
      @journal_entry.postings.build(attrs)
    end
    @cross_entity_rerender = copy[:rerender]
    load_form_data
    # A pro needs nothing beyond the plain copy notice. A non-pro can reach this
    # action only one way — the ledger of one of the entry's own balance
    # accounts — landing here with no warning that this needs the books to stay
    # balanced across more than the two accounts they are used to.
    flash.now[:notice] = current_admin.full_access_pro? ? t("crud.is_copy") : t("journal_entries.duplicate.beginner_warning")
    render :new
  end

  # Renders the two posting rows of one cross-entity linked entry (JE₂) for the
  # modal to insert, namespaced under cross_entity_entries[<idx>]. Rendering
  # only — the save happens on the main form submit.
  def cross_entity_rows
    gift_side    = params[:gift_side].to_s
    capital_side = gift_side == "debit" ? "credit" : "debit"

    if params[:capital_posting_id].present? && params[:nominal_posting_id].present?
      # Editing a persisted leg: render the REAL postings so they stay saved and
      # the receipt widget keys to the real posting. The modal's new
      # account/amount/side are applied in memory only; the form submit persists
      # them.
      linked  = accessible_postings.find(params[:capital_posting_id]).journal_entry
      capital = linked.postings.detect { |p| p.id.to_s == params[:capital_posting_id].to_s }
      nominal = linked.postings.detect { |p| p.id.to_s == params[:nominal_posting_id].to_s }
      capital&.assign_attributes(account_id: params[:capital_account_id], entry_type: capital_side, cross_entity_link_id: params[:link_id])
      nominal&.assign_attributes(account_id: params[:nominal_account_id], entry_type: gift_side)
    else
      linked = JournalEntry.new
      linked.postings.build(account_id: params[:capital_account_id],
                            entry_type: capital_side, cross_entity_link_id: params[:link_id])
      linked.postings.build(account_id: params[:nominal_account_id], entry_type: gift_side)
    end

    render partial: "cross_entity_rows", layout: false, locals: {
      linked:      linked,
      entry_index: params[:entry_index].to_s,
      link_id:     params[:link_id].to_s,
      amount:      params[:amount].to_s,
      context:     params[:context].to_s # "bank" hides the entry_type column
    }
  end

  private

  def set_journal_entry
    @journal_entry = accessible_journal_entries.includes(postings: [:receipts, :account]).find(params[:id])
  end

  # POSTING_PARAMS + save_with_cross_entity_entries +
  # cross_entity_entries_params
  # live in the CrossEntityJournalEntries concern (shared with bank entries).
  def journal_entry_params
    params.require(:journal_entry).permit(
      :entry_date, :memo, :journal_reference,
      # The period is derived, not submitted — see
      # JournalEntry#derive_closing_period.
      :closing_entry,
      postings_attributes: POSTING_PARAMS
    )
  end

  def export_csv(scope)
    filtered_ids = scope.select(:id)
    data = accessible_journal_entries
      .where(id: filtered_ids)
      .joins(:postings)
      .group('journal_entries.id, journal_entries.entry_date, journal_entries.memo, journal_entries.journal_reference')
      .order(entry_date: :desc)
      .pluck(
        'journal_entries.id',
        'journal_entries.entry_date',
        'journal_entries.memo',
        'journal_entries.journal_reference',
        Arel.sql("SUM(CASE WHEN postings.entry_type = 0 THEN postings.amount ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN postings.entry_type = 1 THEN postings.amount ELSE 0 END)")
      )

    csv_data = data.map do |id, date, memo, ref, debits, credits|
      [id, date.strftime('%Y-%m-%d'), memo, ref,
       helpers.format_amount_csv(debits), helpers.format_amount_csv(credits)]
    end

    stream_csv_from_array(
      filename: "journal_entries_#{Date.current}.csv",
      headers: %w[ID Date Memo JournalReference Debit Credit],
      data: csv_data
    )
  end

  def filtered_journal_entries
    scope = accessible_journal_entries.default_order
    if params[:start_date].present? && params[:end_date].present?
      scope = scope.by_date_range(params[:start_date].to_date, params[:end_date].to_date)
    end
    scope = scope.search_filter(params[:search]) if params[:search].present?
    scope
  end

  def load_posting_display_data(je_ids)
    balance_sheet_types = %w[asset liability equity]
    posting_data = accessible_postings
      .where(journal_entry_id: je_ids)
      .joins(:account)
      .pluck(
        :journal_entry_id,
        :entry_type,
        :amount,
        :currency,
        'accounts.code',
        'accounts.name',
        'accounts.account_type',
        :cross_entity_link_id,
        'accounts.locked'
      )

    @balance_account = {}
    @credit_sums = {}
    @credit_currency = {}
    @cross_entity_je_ids = Set.new # JEs with a linked posting → "linked" cue in the index
    # Closing entries the year-end flow generated post to a locked retained-
    # earnings account and are read-only, so their rows offer no copy or edit.
    # Collected here rather than asked per row.
    @app_owned_close_ids = Set.new

    posting_data.each do |je_id, entry_type, amount, currency, code, name, account_type, link_id, locked|
      @app_owned_close_ids << je_id if locked && account_type == 'equity'
      if balance_sheet_types.include?(account_type)
        @balance_account[je_id] ||= "#{code} - #{name}"
        @credit_currency[je_id] ||= currency
      end
      if entry_type == 'credit'
        @credit_sums[je_id] ||= { amount: 0 }
        @credit_sums[je_id][:amount] += amount
      end
      @cross_entity_je_ids << je_id if link_id.present?
    end
  end
end
