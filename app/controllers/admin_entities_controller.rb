# frozen_string_literal: true

# The Remove button behind the authorised-access table: one entity link at a
# time.
# Sudo removes full_access rows only; a full-access admin removes
# read_only/upload_receipts rows on their own entities. Sudo never touches a
# lower grant, granting or revoking — that is the full-access admin's business
# alone.
class AdminEntitiesController < BaseController
  before_action :set_admin_entity, only: [ :destroy ]

  # Silent refusal by design: the button only renders when #may_remove? is
  # already true, so reaching a refusal here means a crafted request.
  def destroy
    unless may_remove?(@admin_entity)
      redirect_to dashboard_path, alert: t("admins.access_denied")
      return
    end

    @admin_entity.destroy
    # Sudo holds no entities and so has no authorised table of their own — back
    # to the admin list. Everyone else returns to their own page, where the
    # table lives.
    redirect_to (sudo? ? admins_path : admin_path(current_admin)),
                status: :see_other, notice: t("admins.access_removed")
  end

  private

  def set_admin_entity
    @admin_entity = AdminEntity.find(params[:id])
  end

  def may_remove?(admin_entity)
    admin_entity.removable_by?(current_admin)
  end
end
