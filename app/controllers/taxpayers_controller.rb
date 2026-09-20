# frozen_string_literal: true

# One taxpayer per authority: one per authority you file with doing your own
# books, one per client per authority keeping several.
#
# Never scoped to an entity — a taxpayer files for several sets of books, which
# is what gives them one login and one copy of the number.
#
# Two scopes. Admin#usable_taxpayers is what you may FILE with, including
# anything already filing for an entity you can write to, so a bookkeeper and
# their assistant share one grant. The record itself stays with whoever created
# it: only they may edit or delete it.
class TaxpayersController < BaseController
  before_action :set_taxpayer, only: [ :edit, :update, :destroy ]
  layout "accounting"

  def index
    @taxpayers = current_admin.usable_taxpayers
                              .includes(report_groups: :entity)
                              .order(:authority, :label, :id)
    @back_path = safe_return_to || dashboard_path
  end

  # Always both offers: pick one you already have, or add one. Choosing writes
  # nothing — it fills the picker on the page behind, which still waits for its
  # own Save.
  def choose
    @authority = params[:authority].to_s
    return head(:no_content) if @authority.blank?

    @choices = current_admin.usable_taxpayers.for_authority(@authority).order(:label, :id)
    # The authority's display name: key to connector, connector to the name its
    # catalogue header declares.
    @authority_name = TaxSchemeConfig.authority_for_connector(
      Filing::Base.connectors_for_authority(@authority).first&.connector
    )
    render partial: "choose", layout: false
  end

  def new
    @taxpayer = current_admin.taxpayers.new(authority: params[:authority])
    # Opened from the tax setup page's modal, so the authority is already
    # decided by which block was clicked and is shown rather than chosen.
    return unless params[:modal].present? && @taxpayer.authority.present?

    render partial: "form", layout: false,
           locals: { form_url: taxpayers_path, modal: true }
  end

  # JSON as well as HTML: the tax setup page adds a taxpayer in a modal and
  # needs the new record back for the picker. Saving it commits nothing about
  # the tax setup, which still waits for that page's own Save.
  def create
    @taxpayer = current_admin.taxpayers.new(authority: taxpayer_params[:authority])
    apply_details

    if @taxpayer.save
      respond_to do |format|
        format.json { render json: { id: @taxpayer.id, display_name: @taxpayer.display_name } }
        format.html { redirect_to taxpayers_path(return_to: params[:return_to].presence),
                                  notice: t("filing.register.saved") }
      end
    else
      respond_to do |format|
        format.json { render json: { errors: @taxpayer.errors.full_messages },
                             status: :unprocessable_entity }
        format.html { render :new, status: :unprocessable_entity }
      end
    end
  end

  def edit; end

  def update
    apply_details
    if @taxpayer.save
      redirect_to taxpayers_path(return_to: params[:return_to].presence), notice: t("filing.register.saved")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Blocked while any tax report group still names it
  # (Taxpayer#ensure_not_in_use). Detaching silently would leave those books
  # unfilable with nothing on screen to say why, and the entity may not even be
  # one this admin can see.
  def destroy
    back = taxpayers_path(return_to: params[:return_to].presence)
    if @taxpayer.destroy
      redirect_to back, notice: t("filing.register.deleted")
    else
      redirect_to back, alert: in_use_alert(@taxpayer)
    end
  end

  private

  # return_to is followed only when it resolves to a page the user could
  # genuinely have arrived from — the tax setup page or their own profile.
  # Anything else falls back to the dashboard rather than following a parameter
  # blindly.
  def safe_return_to
    raw = params[:return_to].to_s
    # A bare local path: leading slash, then word characters and slashes only.
    # No host, no query string, no "..".
    return unless raw.match?(%r{\A/[\w\-/]+\z})

    route = Rails.application.routes.recognize_path(raw)
    return raw if route[:controller] == "entities" && route[:action] == "edit_tax"
    return raw if route[:controller] == "admins"   && route[:action] == "show"

    nil
  rescue ActionController::RoutingError
    nil
  end

  # The admin's OWN, not the usable set: editing a number or deleting a record
  # is the creator's to do. Anyone else who needs it can still file with it.
  def set_taxpayer
    @taxpayer = current_admin.taxpayers.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    deny_access(t("access.read_only_deny"), taxpayers_path)
  end

  # Names the entities still filing with it, and says plainly when some of them
  # are not this admin's to see — "still in use" with nothing to act on is a
  # dead end.
  def in_use_alert(taxpayer)
    codes  = taxpayer.entity_codes_in_use
    mine   = codes & current_admin.writable_entity_codes
    hidden = codes.size - mine.size

    parts = [ t("filing.register.still_in_use") ]
    parts << t("filing.register.still_in_use_entities", entities: mine.join(", ")) if mine.any?
    parts << t("filing.register.still_in_use_hidden", count: hidden) if hidden.positive?
    parts.join(" ")
  end

  # Identifiers are whatever the connector declares, normalised by it — only the
  # connector knows its authority's format rules.
  def apply_details
    @taxpayer.label = taxpayer_params[:label].to_s.strip.presence
    Filing::Base.identifiers_for_authority(@taxpayer.authority).each do |key|
      raw = taxpayer_params.dig(:identifiers, key)
      @taxpayer.set_identifier(
        key, Filing::Base.normalise_for_authority(@taxpayer.authority, key, raw)
      )
    end
  end

  def taxpayer_params
    params.require(:taxpayer).permit(:authority, :label, identifiers: {})
  end
end
