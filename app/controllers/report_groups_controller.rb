class ReportGroupsController < BaseController
  before_action :set_report_group, only: [:edit, :update, :destroy, :update_accounts]
  #before_action :set_entity, only: [:index, :new, :create]
  before_action :set_entity, only: [:create]
  # Report groups belong to an entity, so changing one is a write into that
  # entity — full_access only.
  before_action :require_writable_report_group, only: [:edit, :update, :destroy, :update_accounts]
  before_action :require_writable_entity,       only: [:create]


  def show
    @report_group = accessible_report_groups.includes(:reports).find(params[:id])
    @reports = @report_group.reports.order(start_date: :desc)
    return load_tax_assignment if @report_group.tax_report?
    #@selected_accounts = @report_group.accounts.order('report_group_accounts.position')
    #@selected_account_ids = @selected_accounts.pluck(:id)
    @selected_accounts = @report_group.accounts.order('report_group_accounts.position').to_a
    @selected_account_ids = @selected_accounts.map(&:id)

    # Use existing accessible_accounts from current admin
    @available_accounts = current_admin.accessible_accounts.active.leaf_accounts.ordered

    # Group by parent for display
    @accounts_by_parent = @available_accounts.group_by { |a| a.code[0, 4] }

    # Preload parent accounts to avoid N+1
    parent_codes = @accounts_by_parent.keys.map { |code| "#{code}00" }
    @parent_accounts = Account.where(code: parent_codes).index_by { |a| a.code[0, 4] }
  end
  

  def create
    @report_group = @entity.report_groups.build(report_group_params)
#      entity_id = Entity.where(code: current_admin.entity_code).pick(:id)
    if @report_group.save
      redirect_to dashboard_path, notice: t("report_groups.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    redirect_to report_group_path(@report_group) if @report_group.tax_report?
  end

  def update
    # Nothing on a tax report group is editable: its name is declared by the
    # scheme and its accounts follow the tagging, not a curated list. Assignment
    # happens in bulk on its show page, or per account on the account's own edit
    # page.
    if @report_group.tax_report?
      redirect_to report_group_path(@report_group),
                  alert: t("report_groups.tax_report_uneditable")
      return
    end

    if @report_group.update(report_group_params)
      redirect_to report_group_path(@report_group), notice: t("report_groups.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def update_accounts
    account_data = params.permit(accounts: [:id, :position]).fetch(:accounts, [])

    @report_group.transaction do
      @report_group.report_group_accounts.delete_all  # Single DELETE query
  
      return render json: { success: true, count: 0 } if account_data.empty?
  
      records = account_data.map do |item|
        {
          report_group_id: @report_group.id,
          account_id: item[:id],
          position: item[:position],
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      ReportGroupAccount.insert_all(records)  # Single INSERT query
    end

    render json: { success: true, count: account_data.size }
  rescue => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end
      
  def destroy
    # A tax report group belongs to its scheme, not to the admin: it appears on
    # subscribing and goes when the scheme is discontinued. Deleting it by hand
    # would leave the scheme with nowhere to show its accounts. The button is
    # hidden too — this refuses the route.
    unless @report_group.deletable?
      redirect_to dashboard_path, alert: t("report_groups.tax_report_undeletable")
      return
    end

    # deletable? already guarantees reports.empty? for a tax report group, so
    # releasing here is always safe — the same release unsubscribing triggers.
    # No-ops for a custom group, whose tax_scheme is nil.
    Account.release_from_scheme(entity_code: @report_group.entity.code, scheme: @report_group.tax_scheme)

    @report_group.destroy
    redirect_to dashboard_path, notice: t("report_groups.deleted")
  end

  private

  # A tax report has no curated account list — its accounts ARE the accounts
  # tagged with its scheme, so its page is where the tagging happens: assigned
  # on the left, unassigned on the right. Both sides write tax_scheme and
  # tax_category_key onto the account; nothing about membership is stored.
  def load_tax_assignment
    scheme  = @report_group.tax_scheme
    entity  = @report_group.entity

    @assigned = @report_group.accounts_scope.to_a

    # Offered on the right: this entity's leaf income/expense accounts that no
    # return it files has claimed. An account belongs to exactly one scheme, so
    # one tagged to another scheme this entity files stays out of here.
    #
    # One tagged to a scheme the entity has SINCE DROPPED does belong here,
    # though: the group went with the subscription, so it has no assign page of
    # its own any more and leaving it out makes it invisible.
    @unassigned = Account.unmapped_for_tax(entity_codes: [ entity.code ]).to_a

    @tax_category_options = TaxCategory.grouped_options(scheme)

    # Suggestions come from THIS scheme's catalogue and no other, read off the
    # account's name (TaxCategoryGuesser). Nothing is saved until the + is
    # clicked.
    @tax_suggestions = TaxCategoryGuesser.for_scheme(scheme)
                                              .guess_all(@unassigned)
                                              .transform_values { |key| "#{scheme}::#{key}" }
    render :show
  end

  def set_report_group
    @report_group = accessible_report_groups.find(params[:id])
  end

  def set_entity
    @entity = accessible_entities.find(params[:entity_id])
  end

  def report_group_params
    params.require(:report_group).permit(:name, :description)
  end
end