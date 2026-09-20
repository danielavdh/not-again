class AdminsController < ApplicationController
  # Sudo manages any account. Everyone else reaches only their own — a claimed
  # coadmin owns their identity fields.
  # verify_email skips every gate below: the token is the authorisation.
  before_action :ensure_full_access_or_self
  require_claim
  require_otp
  require_terms
  allow_unauthenticated_access only: [ :verify_email ]
  skip_before_action :ensure_full_access_or_self, :require_claim_completed, :require_otp_verification, :require_terms_agreement, only: [ :verify_email ]
  before_action :require_sudo_only, only: [:index]
  before_action :set_admin, only: %i[show edit update destroy update_preferences resend_claim_email]
  before_action :set_title
  helper_method :grant_path?, :show_new_person_fields?
  # Routes sit outside the accounts subdomain constraint, so this answers on
  # both hosts and has to wear the menu of whichever one it was reached on.
  layout "accounting"

  # GET /admins — sudo only
  def index
    @admins = Admin.all.includes(admin_entities: :entity)
  end

  # GET /admins/:id
  def show
    @managed_admins = @admin.managed_admins.to_a
    # Only the links on @admin's own full-access entities — never the whole
    # association, which would load entities this page must not show.
    @shared_links   = @admin.shared_admin_entities_by_admin(@managed_admins)
    # Read twice by the view, so loaded once here.
    @admin_entities = @admin.admin_entities.includes(entity: :entity_group).references(:entity).order("entities.code").to_a
    # Shown as the blank option, so the automatic choice is visible.
    @derived_currency = session[:default_currency] || "EUR"
    @entity_access_rows = entity_access_rows
  end

  # GET /admins/new
  def new
    @admin = Admin.new
    @mode = sudo? ? :sudo : :invite
    @manageable_entities = manageable_entities_for_grant
  end

  # GET /admins/:id/edit
  # Sudo's only place to see and remove full_access links.
  # read_only/upload_receipts grants belong to the full-access admin, never
  # sudo.
  def edit
    @mode = sudo? ? :sudo : :self
    @full_access_entities = @admin.admin_entities.with_full_access.includes(:entity).order("entities.code") if sudo?
  end

  # POST /admins
  # No entity checked means sudo creating a bare admin — a full-access admin's
  # form can never submit zero.
  def create
    if sudo? && Array(params[:entity_ids]).blank?
      create_as_sudo
    else
      create_or_grant_coadmin_access
    end
  end

  # PATCH/PUT /admins/:id
  # can_manage?(self) is false for a non-sudo admin by design, so the self
  # clause is what lets them edit their own profile.
  def update
    unless current_admin.can_manage?(@admin) || @admin == current_admin
      redirect_to admin_path(current_admin), alert: t("admins.access_denied")
      return
    end

    if sudo?
      update_as_sudo
    else
      update_as_full_access_admin
    end
  end

  # A full-access admin reaches this only for a draft. draft? is re-checked here
  # rather than trusted from set_admin: a claim can land between the page
  # rendering and this request.
  def destroy
    unless current_admin.can_manage?(@admin)
      redirect_to (sudo? ? admins_path : admin_path(current_admin)),
                  alert: t("admins.cannot_delete")
      return
    end

    if sudo?
      destroy_as_sudo
    elsif @admin.draft?
      destroy_draft_as_full_access_admin
    else
      redirect_to admin_path(current_admin), alert: t("admins.cannot_delete")
    end
  end

  # Non-bang: ensure_an_owner_remains throws :abort, so the last owner falls
  # through to the alert instead of raising.
  def destroy_as_sudo
    unless @admin.destroy
      redirect_to admins_path, alert: t("admins.cannot_delete")
      return
    end

    redirect_to admins_path, status: :see_other, notice: t("admins.deleted", username: @admin.username)
  end

  # The one path that deletes a whole Admin row for a non-sudo admin, and only
  # ever a draft.
  def destroy_draft_as_full_access_admin
    username = @admin.username
    @admin.destroy
    redirect_to admin_path(current_admin), status: :see_other,
                notice: t("admins.draft_deleted", username: username)
  end

  # The granting admin's resend. GatesController#claim_resend is the draft's
  # own, reachable only once they have logged in.
  def resend_claim_email
    unless @admin.draft?
      redirect_to admin_path(current_admin), alert: t("admins.access_denied")
      return
    end

    AdminMailer.with(admin: @admin, granter: current_admin, locale: I18n.locale)
               .email_verification.deliver_later
    redirect_to admin_path(current_admin), notice: t("admins.claim_email_resent")
  end

  def update_preferences
    return redirect_to admin_path(current_admin) unless @admin == current_admin
    # Each preference has its own form, so only touch what was actually
    # submitted — otherwise saving one would silently reset the other.
    prefs = params.require(:admin)
    attrs = {}
    attrs[:show_journal_entries] = prefs[:show_journal_entries] == "1" if prefs.key?(:show_journal_entries)
    # Blank means "work it out from my accounts", the existing behaviour.
    attrs[:preferred_currency]   = prefs[:preferred_currency].presence  if prefs.key?(:preferred_currency)
    # Blank means "follow my language".
    attrs[:preferred_number_format] = prefs[:preferred_number_format].presence if prefs.key?(:preferred_number_format)
    @admin.update!(attrs)
    redirect_to admin_path(@admin), notice: t("admins.preferences_updated")
  end

  # Live check for the grant form, JSON only. No :id, so
  # ensure_full_access_or_self's self branch cannot match — read_only,
  # upload_receipts and demo are refused.
  def email_lookup
    email = params[:email].to_s.strip.downcase
    render json: { exists: email.present? && Admin.exists?(email_address: email) }
  end

  # GET /verify_email/:token — no set_admin: the token is the authorisation.
  def verify_email
    admin = Admin.find_by_token_for(:email_verification, params[:token])
    if admin
      admin.verify!
      redirect_to(authenticated? ? dashboard_path : new_session_path,
        notice: t("admins.email_verifications.verified"))
    else
      redirect_to new_session_path, alert: t("admins.email_verifications.invalid")
    end
  end

  private

  # Per-row view data for the Entities & access block. manages_family? queries,
  # so it is resolved here rather than per row in the view.
  def entity_access_rows
    available_count   = @admin_entities.count { |ae| ae.full_access? && !ae.entity.entity_group_id? }
    assignable_groups = current_admin.assignable_entity_groups

    @admin_entities.map do |ae|
      grouped    = ae.full_access? && ae.entity.entity_group_id?
      may_manage = grouped && current_admin.manages_family?(ae.entity.entity_group)
      offer_join = ae.full_access? && !ae.entity.entity_group_id? &&
                   (available_count > 1 || assignable_groups.any?)

      {
        admin_entity: ae,
        grouped: grouped,
        may_manage: may_manage,
        show_family_field: may_manage || offer_join,
        family_field_groups: may_manage ? [] : assignable_groups,
        family_field_allow_create: !may_manage && available_count > 1
      }
    end
  end


  # A bare admin with no entity links. The only path that can set sudo or
  # otp_enabled.
  def create_as_sudo
    # Never a draft — sudo already controls the whole thing, so there is no
    # "whose password is it really" question the claim flow exists to settle.
    @admin = Admin.new(sudo_admin_params.merge(claimed_at: Time.current))
    @mode = :sudo
    @manageable_entities = manageable_entities_for_grant

    if @admin.save
      AdminMailer.with(admin: @admin, locale: I18n.locale).email_verification.deliver_later
      redirect_to admins_url, notice: "Admin was successfully created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # The one grant path. A full-access admin grants read_only/upload_receipts on
  # entities they manage; sudo grants full_access on any entity.
  def create_or_grant_coadmin_access
    @mode = sudo? ? :sudo : :invite
    @manageable_entities = manageable_entities_for_grant

    # Intersect in Ruby: @manageable_entities carries an includes that fans out
    # duplicate rows under pluck, and .distinct collides with its own order.
    allowed_ids = @manageable_entities.unscope(:order, :includes).pluck(:id)
    entity_ids = allowed_ids & Array(params[:entity_ids]).map(&:to_i)
    if entity_ids.empty?
      @admin = Admin.new(coadmin_params)
      @admin.errors.add(:base, "Please select at least one entity")
      render :new, status: :unprocessable_entity
      return
    end

    levels_by_entity_id = resolve_levels_by_entity_id(entity_ids)
    if levels_by_entity_id.nil?
      redirect_to new_admin_path, alert: t("admins.invalid_access_level")
      return
    end

    existing = find_existing_coadmin_candidate
    return grant_existing_admin_access(existing, levels_by_entity_id) if existing

    # An owner's email otherwise falls through to Admin.new and dies on the
    # email uniqueness constraint. Reuses already_linked deliberately — a
    # message of its own would confirm which addresses belong to owners.
    if Admin.exists?(email_address: submitted_email, sudo: true)
      redirect_to new_admin_path, alert: t("admins.already_linked", username: submitted_email)
      return
    end

    @admin = Admin.new(coadmin_params)

    if @admin.save
      levels_by_entity_id.each do |eid, level|
        AdminEntity.create!(admin: @admin, entity_id: eid, access_level: level)
      end
      AdminMailer.with(admin: @admin, granter: current_admin, locale: I18n.locale)
                 .email_verification.deliver_later
      redirect_to (sudo? ? admins_url : admin_path(current_admin)),
                  notice: t("admins.coadmin_created", username: @admin.username,
                            access: levels_by_entity_id.values.uniq.map(&:humanize).join(", "))
    else
      render :new, status: :unprocessable_entity
    end
  end

  # Never full_access: that would let an inviter create an un-manageable peer at
  # will.
  def allowed_grant_levels
    %w[read_only upload_receipts]
  end

  # Sudo's grant is always full_access. For anyone else nil means the level was
  # not one of the two the form offers, so the request was crafted.
  def resolve_levels_by_entity_id(entity_ids)
    return entity_ids.index_with { "full_access" } if sudo?

    level = params[:access_level]
    return nil unless allowed_grant_levels.include?(level)
    entity_ids.index_with { level }
  end

  # By email, never username: an address is something they gave you, a username
  # collision between strangers is a coincidence.
  def find_existing_coadmin_candidate
    return nil if submitted_email.blank?

    candidate = Admin.find_by(email_address: submitted_email)
    return nil if candidate.nil? || candidate.sudo? || candidate == current_admin

    candidate
  end

  # A second, independent grant — never touches their username or password.
  # Entities they already hold are skipped rather than refused.
  def grant_existing_admin_access(admin, levels_by_entity_id)
    already_linked = admin.admin_entities.where(entity_id: levels_by_entity_id.keys).pluck(:entity_id)
    to_grant = levels_by_entity_id.except(*already_linked)

    if to_grant.empty?
      redirect_to new_admin_path, alert: t("admins.already_linked", username: identifier_for(admin))
      return
    end

    to_grant.each do |eid, level|
      AdminEntity.create!(admin: admin, entity_id: eid, access_level: level)
    end

    # One submission grants one level across every entity, so every value here
    # is identical.
    AdminMailer.with(admin: admin, granter: current_admin, entities: Entity.where(id: to_grant.keys).to_a,
                      level: to_grant.values.first, locale: I18n.locale).access_granted.deliver_later

    redirect_to admin_path(current_admin),
            notice: t("admins.coadmin_linked", 
                  username: identifier_for(admin),
                  access: to_grant.values.uniq.map(&:humanize).join(", "))
  end

  # Sudo manages by username. Every other admin only ever sees another admin's
  # email.
  def identifier_for(admin)
    sudo? ? admin.username : admin.email_address
  end


  def update_as_sudo
    @mode = :sudo
    was_otp_enabled     = @admin.otp_enabled?
    was_owner           = @admin.sudo?

    if @admin.update(sudo_admin_params)
      # If 2FA is being unticked, fully disable it (clear the secret too).
      # Forces fresh enrolment if re-enabled later.
      if was_otp_enabled && !@admin.otp_enabled?
        @admin.disable_otp!
      end

      # An owner's entity links mean nothing — they see and write everything
      # regardless. destroy_all is deliberate: it fires the same orphan-
      # notification callback as leaving a business.
      if !was_owner && @admin.sudo?
        entity_ids_before = @admin.admin_entities.pluck(:entity_id)
        @admin.admin_entities.destroy_all
        @admin.reset_access_cache!
        orphaned_codes = Entity.where(id: entity_ids_before).orphaned.pluck(:code)
        if orphaned_codes.any?
          flash[:alert] = t("admins.promoted_orphan_warning", codes: orphaned_codes.join(", "))
        end
      end

      resend_verification_if_email_changed
      redirect_to admins_url, notice: "Admin was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Always a self-edit: set_admin never hands a non-sudo admin anyone else.
  def update_as_full_access_admin
    @mode = :self

    if @admin.update(coadmin_params)
      resend_verification_if_email_changed
      redirect_to admin_path(current_admin), notice: "Your profile was updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # The model's callback clears verified_at when the address changes; this is
  # the half that sends the new one something to confirm.
  def resend_verification_if_email_changed
    return unless @admin.saved_change_to_email_address?
    AdminMailer.with(admin: @admin, locale: I18n.locale).email_verification.deliver_later
  end

  # Two separate methods — never mix them.

  # Sudo can set everything
  def sudo_admin_params
    permitted = params.require(:admin).permit(
      :username, :password, :password_confirmation,
      :email_address, :entity_code, :otp_enabled, :last_seen, :sudo
    )
    permitted.delete(:password) if permitted[:password].blank?
    permitted.delete(:password_confirmation) if permitted[:password].blank?
    permitted
  end

  # No :sudo, no entity_code, no otp_enabled — permitting :sudo would let a
  # full-access admin escalate through an admin they manage.
  def coadmin_params
    permitted = params.require(:admin).permit(
      :username, :email_address, :password, :password_confirmation
    )
    permitted.delete(:password) if permitted[:password].blank?
    permitted.delete(:password_confirmation) if permitted[:password].blank?
    permitted
  end

  # Preloaded for the per-entity "already granted" hint on the form.
  def manageable_entities_for_grant
    (sudo? ? Entity.active : current_admin.manageable_entities)
      .order(:code).includes(admin_entities: :admin)
  end

  # True only on new's own render. Sudo editing an existing admin shares @mode
  # but is persisted.
  def grant_path?
    @mode == :invite || (@mode == :sudo && !@admin.persisted?)
  end

  # The email field's own value, re-read from params on an error re-render —
  # @admin has already failed to save, so it can't be trusted as the source.
  def submitted_email
    params.dig(:admin, :email_address).to_s.strip.downcase
  end

  # Opens the username/password fields only once an error re-render shows the
  # address is not an existing admin. index.js does the same check live.
  def show_new_person_fields?
    grant_path? && submitted_email.present? && !Admin.exists?(email_address: submitted_email)
  end


  # A non-sudo admin is only ever handed themselves. The draft branch is the one
  # exception — destroy and resend_claim_email only, never a claimed coadmin,
  # and #destroy re-checks draft? rather than trusting this.
  def set_admin
    if sudo?
      @admin = Admin.find(params[:id])
    elsif params[:id].to_i == current_admin.id
      @admin = current_admin
    elsif current_admin.full_access? && action_name.in?(%w[destroy resend_claim_email])
      @admin = Admin.joins(:admin_entities)
                     .where(admin_entities: { entity_id: current_admin.admin_entities.with_full_access.select(:entity_id) })
                     .where(claimed_at: nil)
                     .distinct
                     .find(params[:id])
    else
      redirect_to dashboard_path, alert: t("admins.access_denied")
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to admin_path(current_admin), alert: t("admins.not_found")
  end

  # Anyone signed in reaches their OWN actions here. new/create carry no :id, so
  # they fall through to the full_access branch.
  def ensure_full_access_or_self
    return if sudo?
    return if admin_signed_in? && current_admin.full_access?
    return if admin_signed_in? && current_admin.demo? && demo_may_look?
    # Never demo, even on their own id: this branch has no method restriction of
    # its own, so without the guard it overrides demo's GET-only rule.
    return if admin_signed_in? && !current_admin.demo? &&
              params[:id].present? && params[:id].to_i == current_admin.id
    return redirect_to_login unless admin_signed_in?

    redirect_to dashboard_path, alert: t("admins.access_denied")
  end

  def set_title
    @title = "Admin"
  end
end
