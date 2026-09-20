class DashboardController < BaseController
  layout "accounting"

  def index
    # :taxpayer as well as :reports — the tax row asks each group whether its
    # authority is connected yet (Entity#filing_offers), which is otherwise a
    # query per scheme per entity.
    @entities = accessible_entities
      .includes(:entity_group, report_groups: [ :reports, :taxpayer ])
      .order(:code)
    
    @common_asset_accounts = accessible_accounts
      .balance_accounts
      .leaf_accounts
      .left_joins(:postings)
      .group(:id)
      .order('COUNT(postings.id) DESC')
      .limit(5)
    @ids = @common_asset_accounts.map(&:id)
    @balances = Account.balances_for(@ids)

    # Primary entity for single-entity view / report groups
    @entity = accessible_entities.active
      .includes(report_groups: [ :reports, :taxpayer ])
      .find_by(code: current_admin.primary_entity_code)
    @report_groups = @entity&.report_groups&.sort_by(&:position) || []

  end

end
