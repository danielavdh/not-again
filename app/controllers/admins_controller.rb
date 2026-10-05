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
  # Making an account is installation management. Granting access to one is not,
  # and lives in #grant_access / #create_grant, which a full-access admin reaches
  # from their own page.
  before_action :require_sudo_only, only: [ :index, :new, :create ]
  before_action :set_admin, only: %i[show edit update destroy update_preferences resend_claim_email]
  before_action :set_title
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

  # GET /admins/new — sudo only: an account, with no books attached. Access is
  # granted on its own page, so there are no entity boxes here and no password
  # either: #create_as_sudo generates one, and the claim flow replaces it.
  def new
    @admin = Admin.new
    @mode  = :sudo
  end

  # GET /admins/grant_access — "give this person access to these entities".
  # Creates the account as a side effect when the address is new, which is the
  # usual case for a full-access admin inviting a coadmin.
  def grant_access
    @admin = Admin.new
    @mode  = sudo? ? :sudo : :invite
    load_grant_data
  end

  # GET /admins/access_fields?email=… — the entity-access block for whoever that
  # address belongs to. The form fetches it as the email is typed, so the ticks
  # show that person's CURRENT access instead of a blank slate, and sudo can
  # revoke here by unticking.
  # No :id, so ensure_full_access_or_self's self branch cannot match — read_only,
  # upload_receipts and demo are refused.
  def access_fields
    @mode = sudo? ? :sudo : :invite
    load_grant_data(email: params[:email], username: params[:username])
    render partial: "admins/entity_access_fields",
           locals: { rows: @grant_rows, target: @grant_target, orphan_codes: @orphan_codes,
                     identifier_conflict: @identifier_conflict, form: nil,
                     create_prompt: @create_prompt }
  end

  # GET /admins/:id/edit
  # Sudo's only place to see and remove full_access links.
  # read_only/upload_receipts grants belong to the full-access admin, never
  # sudo.
  def edit
    @mode = sudo? ? :sudo : :self
    @full_access_entities = @admin.admin_entities.with_full_access.includes(:entity).order("entities.code") if sudo?
  end

  # POST /admins — sudo only, and only ever an account.
  def create
    create_as_sudo
  end

  # POST /admins/grant_access — one job, two shapes. An identifier that already
  # belongs to an admin changes THEIR access and creates nothing; an unknown one
  # drafts the account and grants in the same submission.
  def create_grant
    if identified_admin == :conflict
      @mode = sudo? ? :sudo : :invite
      load_grant_data
      @admin = Admin.new(invitee_params)
      @admin.errors.add(:username, :taken)
      return render(:grant_access, status: :unprocessable_entity)
    end

    if (existing = find_existing_coadmin_candidate)
      sudo? ? reconcile_full_access(existing) : grant_coadmin_access(existing)
    else
      create_and_grant
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
    # Generated, like a drafted coadmin's: sudo controls the account outright and
    # sets a real password through the ordinary edit form or a reset.
    @admin = Admin.new(sudo_admin_params.reverse_merge(password: SecureRandom.base58(24))
                                        .merge(claimed_at: Time.current))
    @mode = :sudo

    if @admin.save
      AdminMailer.with(admin: @admin, locale: I18n.locale).email_verification.deliver_later
      redirect_to admins_url, notice: "Admin was successfully created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # A person nobody has an account for yet: draft it and grant in one go. No
  # password is asked for — one is generated and the claim flow replaces it at
  # their first login, so the inviter never invents or communicates a secret.
  def create_and_grant
    @mode = sudo? ? :sudo : :invite
    load_grant_data

    # Built with the generated password up front so #valid? complains about the
    # identity fields and nothing else.
    @admin = Admin.new(invitee_params.merge(password: SecureRandom.base58(24)))
    entity_ids = submitted_entity_ids

    levels_by_entity_id = resolve_levels_by_entity_id(entity_ids) if entity_ids.any?
    if entity_ids.any? && levels_by_entity_id.nil?
      return redirect_to(grant_access_admins_path, alert: t("admins.invalid_access_level"))
    end

    # Before the model's own validations, which would answer an owner's address
    # with "has already been taken". already_linked is the wording chosen for
    # it: true of an owner, and it singles nobody out.
    if Admin.exists?(email_address: submitted_email, sudo: true)
      redirect_to grant_access_admins_path, alert: t("admins.already_linked", username: submitted_email)
      return
    end

    # Everything else wrong in one pass: the model's own validations for the
    # address and the username, ours for the entities. Reporting them one at a
    # time made a submission with neither answer "select at least one entity"
    # and say nothing about the missing address.
    @admin.valid?
    @admin.errors.add(:entity_ids, t("admins.no_entity_selected")) if entity_ids.empty?
    return render(:grant_access, status: :unprocessable_entity) if @admin.errors.any?

    # A typo in an existing admin's address would otherwise quietly draft a
    # second person and grant them access. Nobody is created until this is
    # ticked.
    if params[:confirm_create].blank?
      @confirm_create = submitted_email
      return render(:grant_access, status: :unprocessable_entity)
    end

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
      render :grant_access, status: :unprocessable_entity
    end
  end

  # A full-access admin grants read_only/upload_receipts to someone who already
  # has an account. Never a revoke: their own authorised table does that, and
  # they may not touch a full_access row at all.
  def grant_coadmin_access(existing)
    @mode = :invite
    load_grant_data

    levels_by_entity_id = submitted_grant_levels
    return if levels_by_entity_id.nil?

    grant_existing_admin_access(existing, levels_by_entity_id)
  end

  # Sudo's half: the ticks ARE this admin's full access, so the submission is a
  # reconciliation — tick to grant, untick to revoke. Only full_access rows are
  # ever touched; a read_only or upload_receipts grant belongs to the admin who
  # made it and is rendered without a box at all.
  #
  # Revoking the last admin of an entity orphans it, which freezes the books,
  # starts the retention clock and emails the admin about it. Recoverable in the
  # data (re-granting clears both columns) but not in the mail, so it is
  # confirmed rather than silently done.
  def reconcile_full_access(target)
    @mode = :sudo
    load_grant_data(email: target.email_address)
    ticked = submitted_entity_ids

    held      = target.admin_entities.with_full_access.pluck(:entity_id)
    to_grant  = ticked - held
    # Only what the form actually offered as a box. An unticked box is a
    # deliberate revoke; a box that was never drawn — the block had not loaded,
    # or the request was crafted — must not read as one.
    to_revoke = (held - ticked) & shown_entity_ids

    if to_grant.empty? && to_revoke.empty?
      return redirect_to(grant_access_admins_path, alert: t("admins.access_unchanged", username: identifier_for(target)))
    end

    orphan_codes = entities_left_unattended(target, to_revoke)
    if orphan_codes.any? && params[:confirm_orphan].blank?
      @orphan_codes = orphan_codes
      @admin = Admin.new(email_address: target.email_address)
      return render(:grant_access, status: :unprocessable_entity)
    end

    ActiveRecord::Base.transaction do
      # One row per admin per entity, so a lower grant is RAISED rather than
      # joined by a second row. Unticking later removes it outright: sudo may not
      # choose read_only, so there is nothing to fall back to.
      to_grant.each do |eid|
        link = target.admin_entities.find_by(entity_id: eid)
        link ? link.update!(access_level: :full_access)
             : AdminEntity.create!(admin: target, entity_id: eid, access_level: :full_access)
      end
      AdminEntity.where(admin_id: target.id, entity_id: to_revoke).with_full_access.destroy_all
    end

    if to_grant.any?
      AdminMailer.with(admin: target, granter: current_admin, entities: Entity.where(id: to_grant).to_a,
                       level: "full_access", locale: I18n.locale).access_granted.deliver_later
    end

    redirect_to admins_url, notice: t("admins.access_reconciled", username: identifier_for(target))
  rescue ActiveRecord::RecordInvalid => e
    @admin = Admin.new(email_address: target.email_address)
    @admin.errors.add(:base, e.record.errors.full_messages.to_sentence)
    render :grant_access, status: :unprocessable_entity
  end

  # The codes of the entities among `entity_ids` that would be left with no
  # admin at all once this admin's link goes. One query, a subselect rather than
  # a count per entity.
  def entities_left_unattended(target, entity_ids)
    return [] if entity_ids.empty?

    still_held = AdminEntity.where(entity_id: entity_ids).where.not(admin_id: target.id).select(:entity_id)
    Entity.where(id: entity_ids).where.not(id: still_held).order(:code).pluck(:code)
  end

  # What every rendering of the grant form needs. `email` resolves the person
  # the ticks are ABOUT; without one the form is a blank create.
  def load_grant_data(email: nil, username: nil, orphan_codes: [])
    @manageable_entities = manageable_entities_for_grant
    found                = identified_admin(email: email, username: username)
    # The same three answers the save acts on, so the page cannot promise one
    # thing and the submission do another.
    @identifier_conflict = (found == :conflict ? taken_username_message : nil)
    @grant_target        = found if found.is_a?(Admin)
    # Submitting would CREATE somebody: nobody holds the address and there is an
    # address to create them with. The sentence is built here so the view never
    # assembles one and the JS never interpolates one.
    address              = email.presence || submitted_email
    @create_prompt       = if found.nil? && address.present?
                             t("admins.form.confirm_create_warning", identifier: address)
                           end
    @orphan_codes        = orphan_codes
    @grant_rows          = grant_rows(@grant_target)
  end

  # One row per entity this admin may grant, carrying what the view must not
  # work out for itself: whether the box starts ticked, whether an existing
  # grant puts the entity out of reach, and who else has full access to it.
  #
  # An entity with no box cannot be unticked away, which is how the levels stay
  # in their own lanes: sudo may change a full_access row and nothing else,
  # while a full-access admin only ever ADDS, so any grant the target already
  # holds is out of their reach.
  #
  # A re-render after an error or an orphan warning takes the ticks from the
  # submission — what they just chose — rather than from the database.
  def grant_rows(target)
    submitted = params.key?(:entity_ids) ? Array(params[:entity_ids]).map(&:to_s) : nil
    links     = target ? target.admin_entities.index_by(&:entity_id) : {}

    @manageable_entities.map do |entity|
      link = links[entity.id]
      {
        entity: entity,
        # Ticked means "has full access". Sudo may raise a lower grant to it, so
        # the box is drawn either way and starts unticked.
        checked: submitted ? submitted.include?(entity.id.to_s) : (sudo? && link&.full_access?),
        # A box a full-access admin may not have: they only ever ADD, so
        # anything the person already holds is out of their reach.
        locked_level: (!sudo? && link.present?) ? link.access_level : nil,
        # What sudo would be raising from, shown next to the box.
        current_level: (sudo? && link.present? && !link.full_access?) ? link.access_level : nil,
        others: entity.admin_entities.select { |ae| ae.full_access? && ae.admin_id != target&.id }
                      .map { |ae| ae.admin.username }
      }
    end
  end

  # The ticked entities and the level to grant them at, or nil once this has
  # already answered the request — no entity ticked, or a level the form does
  # not offer, which means a crafted submission.
  def submitted_grant_levels
    entity_ids = submitted_entity_ids
    if entity_ids.empty?
      @admin = Admin.new(invitee_params)
      @admin.errors.add(:entity_ids, t("admins.no_entity_selected"))
      render :grant_access, status: :unprocessable_entity
      return nil
    end

    levels = resolve_levels_by_entity_id(entity_ids)
    return levels unless levels.nil?

    redirect_to grant_access_admins_path, alert: t("admins.invalid_access_level")
    nil
  end

  # The entities the rendered block drew a checkbox for, as it says itself.
  def shown_entity_ids
    params[:shown_entity_ids].to_s.split(",").map(&:to_i)
  end

  # Intersect in Ruby: @manageable_entities carries an includes that fans out
  # duplicate rows under pluck, and .distinct collides with its own order.
  def submitted_entity_ids
    allowed_ids = @manageable_entities.unscope(:order, :includes).pluck(:id)
    allowed_ids & Array(params[:entity_ids]).map(&:to_i)
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

  # Who this submission is about — asked ONCE, by both the live lookup and the
  # save, so what the page shows and what submitting does cannot drift apart.
  # Returns an Admin, :conflict, or nil.
  #
  # THE ADDRESS IS THE IDENTITY, and the only one. The username names a NEW
  # person and never identifies an existing one — otherwise emptying a field
  # would silently move the form from "create someone" to "change daniela's
  # access", with nothing said and nobody asked.
  #
  # :conflict is a username that belongs to somebody this address does not: it
  # identifies nobody here, and it cannot be given to a new person either.
  # Reported as an ordinary taken-username error, which is true and says
  # nothing about whose it is.
  def identified_admin(email: submitted_email, username: submitted_username)
    address = email.to_s.strip.downcase
    name    = username.to_s.strip
    by_email    = Admin.find_by(email_address: address) if address.present?
    by_username = Admin.find_by(username: name)         if name.present?

    return :conflict if by_username.present? && by_username != by_email
    return nil if by_email.nil? || by_email.sudo? || by_email == current_admin

    by_email
  end

  def find_existing_coadmin_candidate
    found = identified_admin
    found.is_a?(Admin) ? found : nil
  end

  # Rails' own words for a taken unique column, so the live hint and the
  # rejected save say the same thing in every language.
  def taken_username_message
    probe = Admin.new
    probe.errors.add(:username, :taken)
    probe.errors.full_messages.first
  end

  def submitted_username
    params.dig(:admin, :username).to_s.strip
  end

  # A second, independent grant — never touches their username or password.
  # Entities they already hold are skipped rather than refused.
  def grant_existing_admin_access(admin, levels_by_entity_id)
    already_linked = admin.admin_entities.where(entity_id: levels_by_entity_id.keys).pluck(:entity_id)
    to_grant = levels_by_entity_id.except(*already_linked)

    if to_grant.empty?
      redirect_to grant_access_admins_path, alert: t("admins.already_linked", username: identifier_for(admin))
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

  # The grant form has no password field: one is generated and the claim flow
  # replaces it at first login. Taking the identifiers only also stops a
  # submitted confirmation colliding with the generated value.
  def invitee_params
    params.require(:admin).permit(:username, :email_address)
  end

  # Preloaded for the per-entity "already granted" hint on the form.
  def manageable_entities_for_grant
    (sudo? ? Entity.active : current_admin.manageable_entities)
      .order(:code).includes(admin_entities: :admin)
  end


  # The email field's own value, re-read from params on an error re-render —
  # @admin has already failed to save, so it can't be trusted as the source.
  def submitted_email
    params.dig(:admin, :email_address).to_s.strip.downcase
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
