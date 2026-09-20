# frozen_string_literal: true

class FilingController < BaseController
  # :view is reachable from the emailed confirmation link, so it authenticates
  # via a signed token rather than a session (see #authorize_view). The other
  # member actions require a logged-in admin with edit rights.
  AUTHED_MEMBER_ACTIONS = [:connect, :disconnect, :periods, :submit, :report].freeze
  FILING_MEMBER_ACTIONS = (AUTHED_MEMBER_ACTIONS + [:view]).freeze
  VIEW_TOKEN_TTL = 30.days

  require_sudo except: FILING_MEMBER_ACTIONS + [:callback]

  # The emailed link carries a signed token instead of a session, so :view opts
  # out of the admin/session before_actions. A logged-in admin without a token
  # is still accepted via the in-app path in #authorize_view.
  allow_unauthenticated_access only: :view
  skip_before_action :ensure_admin,             only: :view
  skip_before_action :require_accounts_access,  only: :view
  skip_before_action :require_otp_verification, only: :view
  skip_before_action :require_write_access,     only: :view

  before_action :set_accessible_entity,  only: AUTHED_MEMBER_ACTIONS
  before_action :require_tax_edit_access, only: AUTHED_MEMBER_ACTIONS
  before_action :set_filing_service,      only: AUTHED_MEMBER_ACTIONS
  before_action :prepare_authority_request, only: [:periods, :submit, :callback]
  before_action :authorize_view,          only: :view

  # The stored submission is a self-contained document with its own inline
  # styles, which the production CSP would otherwise block. Safe to disable — it
  # is our own generated content.
  content_security_policy false, only: :view

  # Signed token for the emailed "view submission" link. Binds entity, scheme
  # and period so the link cannot be walked to another period, and expires so an
  # old email cannot reveal the document forever.
  def self.view_token(entity_id:, scheme:, period_id:)
    view_token_verifier.generate(
      { "entity_id" => entity_id, "scheme" => scheme, "period_id" => period_id },
      expires_in: VIEW_TOKEN_TTL, purpose: :filing_view
    )
  end

  def self.verify_view_token(token)
    return nil if token.blank?
    view_token_verifier.verify(token, purpose: :filing_view)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def self.view_token_verifier
    Rails.application.message_verifier("acc:filing_view")
  end

  # GET /entities/:entity_id/filing/connect?connector=hmrc_mtd
  def connect
    state = SecureRandom.hex(20)
    session[:filing_oauth_state]        = state
    session[:filing_oauth_entity_id]    = @entity.id
    session[:filing_oauth_type]         = @connector
    # WHOSE permission this is. Carried through the round trip because the
    # callback returns knowing only which connector sent it, and an admin may
    # hold several taxpayers at one authority.
    session[:filing_oauth_taxpayer] = @taxpayer&.id
    # The callback URL carries no locale (see filing_callback_uri), so the
    # language the user was reading in has to survive the round trip here.
    session[:filing_oauth_locale]    = I18n.locale.to_s

    redirect_to @filing.connect_url(callback_uri: filing_callback_uri, state: state),
                allow_other_host: true
  end

  # GET /entities/filing_callback
  # ONE endpoint for every authority: the connector is read from the session,
  # not from the path. Which URI was actually registered with the authority is
  # the connector's business — see Filing::Base.registered_callback_path.
  def callback
    # Read, not deleted: the failure messages below name the authority, and the
    # state check can fail before anything else has been resolved.
    connector = session[:filing_oauth_type]
    authority   = TaxSchemeConfig.authority_for_connector(connector)

    unless params[:state].present? && params[:state] == session.delete(:filing_oauth_state)
      return redirect_to dashboard_path,
                         alert: t("filing.state_mismatch", authority: authority)
    end

    entity_id       = session.delete(:filing_oauth_entity_id)
    taxpayer_id = session.delete(:filing_oauth_taxpayer)
    session.delete(:filing_oauth_type)

    # Back into the language they left in. The callback itself ran under the
    # default locale, because its URL has no locale segment to read one from.
    locale = session.delete(:filing_oauth_locale)
    I18n.locale = locale if locale.present? && I18n.available_locales.map(&:to_s).include?(locale)

    @entity = accessible_entities.find_by(id: entity_id)
    unless @entity
      return redirect_to dashboard_path,
                         alert: t("filing.entity_not_found", authority: authority)
    end

    if params[:error].present?
      return redirect_to edit_tax_entity_path(@entity),
                         alert: t("filing.denied", authority: authority,
                                                       error: params[:error_description])
    end

    # Scoped to the taxpayers this admin may use: a tampered session cannot
    # attach an unrelated taxpayer to a token we just obtained.
    taxpayer = current_admin&.usable_taxpayers&.find_by(id: taxpayer_id)
    unless taxpayer
      return redirect_to edit_tax_entity_path(@entity),
                         alert: t("filing.register.missing", authority: authority)
    end

    filing = Filing::Base.for(connector, entity: @entity, scheme: nil,
                                   admin: current_admin, taxpayer: taxpayer)
    filing.handle_callback(params: params, redirect_uri: filing_callback_uri)

    redirect_to edit_tax_entity_path(@entity),
                notice: t("filing.connected", authority: authority)
  rescue => e
    # The backtrace, not just the message: this rescue catches anything the
    # whole OAuth exchange can throw, and the user only ever sees one sentence
    # in a flash.
    Rails.logger.error "Filing OAuth callback failed for entity #{entity_id}: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.take(15).join("\n")
    redirect_to dashboard_path,
                alert: t("filing.failed", authority: authority, error: e.message)
  end

  # DELETE /entities/:entity_id/filing/disconnect?connector=hmrc_mtd
  def disconnect
    @filing.disconnect
    redirect_to edit_tax_entity_path(@entity),
                notice: t("filing.disconnected", authority: @filing.authority)
  end

  # GET /entities/:entity_id/filing/periods?scheme=self_employment
  def periods
    result       = @filing.periods
    @obligations    = result[:obligations]
    @preview        = result[:preview]
    @error          = result[:error]
    @report_periods = result[:report_periods] || {}
    @business       = result[:business]
    @filed          = result[:filed]
    @panel_partial  = @filing.panel_partial
  end

  # Opens the scheme's tax report over the period the authority asked for, so
  # "what is in this figure?" can be answered at account level — which the
  # submission itself never shows. The dates come from the obligation, widened
  # to the cumulative range for 2025-26 onward, and are not editable; the name
  # is the only thing to choose.
  #
  # Found or created, so revisiting the same period reuses one rather than
  # accumulating duplicates. Asked for, never created as a side effect of
  # following a link.
  #
  # A report is a live query, not a snapshot: it recomputes from the accounts
  # every time it is opened, so it will drift from what was filed if the books
  # change afterwards. The archived submission is the record of what was sent.
  def report
    group = @entity.report_groups.find_by(tax_scheme: @scheme)
    unless group
      redirect_to filing_periods_entity_path(@entity, scheme: @scheme),
                  alert: t("filing.no_report_group")
      return
    end

    start_d, end_d = @filing.report_period(params.require(:period_id))
    # Found or created on the same dates: asking twice for one period should not
    # leave two reports behind.
    report = group.reports.find_or_create_by!(start_date: start_d, end_date: end_d) do |r|
      r.name = params[:name].to_s.strip.presence ||
               "#{l(start_d, format: :short_date)} – #{l(end_d, format: :short_date)}"
    end
    redirect_to report_path(report)
  rescue => e
    Rails.logger.warn "Filing report creation failed for #{@entity.code} #{@scheme}: #{e.message}"
    redirect_to filing_periods_entity_path(@entity, scheme: @scheme),
                alert: t("filing.no_report_group")
  end

  # POST /entities/:entity_id/filing/submit
  def submit
    period_id = params.require(:period_id)
    start_d, end_d = period_id.split("_").map { |d| Date.parse(d) }
    token     = self.class.view_token(entity_id: @entity.id, scheme: @scheme, period_id: period_id)
    view_url  = filing_view_entity_url(@entity, scheme: @scheme, period_id: period_id, sgid: token)

    @filing.submit(period_id: period_id, view_url: view_url) do |locals|
      render_to_string(partial: "filing/submission",
                       locals: locals.merge(scheme_label: TaxSchemeConfig.scheme_label(locals[:scheme])))
    end

    flash[:submitted_period_id] = period_id
    redirect_to filing_periods_entity_path(@entity, scheme: @scheme),
                notice: t("filing.success_with_email",
                          authority: @filing.authority,
                          period: "#{I18n.l(start_d, format: :short_date)} – #{I18n.l(end_d, format: :short_date)}",
                          email: current_admin.email_address)
  rescue => e
    Rails.logger.error "Filing submit failed for #{@entity.code} #{@scheme}: #{e.message}"
    redirect_to filing_periods_entity_path(@entity, scheme: @scheme),
                alert: t("filing.submission_failed", authority: @filing.authority,
                                                         error: e.message)
  end

  # GET /entities/:entity_id/filing/view?scheme=...&period_id=...&sgid=...
  # Reachable via the emailed link (signed token) or in-app (logged-in admin).
  def view
    # A re-submission overwrites the stored document at the same URL, so the
    # browser must never serve a cached copy.
    response.headers["Cache-Control"] = "no-store"
    html = @filing.view_html(period_id: @view_period_id)
    # The stored receipt is a full HTML document with an inline <style>. The
    # dialog fetches it and injects it via innerHTML, where the page's nonce-
    # based style-src CSP blocks that inline style — so for the dialog return
    # only the body content and let the app stylesheet render it. A normal
    # navigation (print) keeps the full document.
    body = request.xhr? ? submission_body(html) : html
    render html: body.html_safe, layout: false
  rescue => e
    Rails.logger.warn "Filing view failed for #{@entity&.code}: #{e.message}"
    render plain: t("filing.not_available"), status: :not_found
  end

  private

  # Inner HTML of the receipt's <body> (header + table), dropping the
  # <head>/<style> so nothing inline is injected into the CSP-governed page.
  def submission_body(html)
    Nokogiri::HTML(html).at("body")&.inner_html || html
  end

  # Lets the connector gather whatever its authority wants from this request.
  # What an authority demands of a request is the connector's knowledge, not
  # this controller's — it serves every connector, so building one authority's
  # browser fingerprint here would do it on the way to authorities that have
  # never heard of it.
  #
  # Resolved from @connector for the member actions, and from the session for
  # :callback, which returns knowing only which connector sent it.
  def prepare_authority_request
    connector = @connector.presence || session[:filing_oauth_type]
    return if connector.blank?

    Filing::Base.connector_class(connector)&.prepare_request(
      request: request, admin: current_admin, cookies: cookies, session: session
    )
  end

  # Resolves @entity, @scheme, @view_period_id and @filing for #view from either
  # a signed token (emailed link, no session) or a logged-in admin (in-app
  # link).
  def authorize_view
    if (payload = self.class.verify_view_token(params[:sgid]))
      @entity         = Entity.find_by(id: payload["entity_id"])
      @scheme         = payload["scheme"]
      @view_period_id = payload["period_id"]
    elsif current_admin
      @entity         = accessible_entities.find_by(id: params[:id])
      @scheme         = params[:scheme]
      @view_period_id = params[:period_id]
      return deny_view unless @entity && (sudo? || can_edit_for_entity?(@entity.code))
    end

    return deny_view unless @entity && @scheme.present? && @view_period_id.present?

    connector = TaxSchemeConfig.connector_for(@scheme)
    @filing = Filing::Base.for(connector, entity: @entity, scheme: @scheme, admin: current_admin)
  rescue => e
    Rails.logger.warn "Filing view authorization failed: #{e.class}: #{e.message}"
    deny_view
  end

  def deny_view
    render plain: t("filing.not_available"), status: :not_found
  end

  def set_accessible_entity
    @entity = accessible_entities.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    deny_access(t("access.read_only_deny"), dashboard_path)
  end

  def require_tax_edit_access
    return unless @entity
    unless sudo? || can_edit_for_entity?(@entity.code)
      deny_access(t("access.read_only_deny"), dashboard_path)
    end
  end

  def set_filing_service
    @connector = if params[:connector].present?
      params[:connector]
    elsif params[:scheme].present?
      @scheme = params[:scheme]
      unless Array(@entity.tax_schemes).include?(@scheme)
        redirect_to edit_tax_entity_path(@entity), alert: t("filing.invalid_scheme")
        return
      end
      TaxSchemeConfig.connector_for(@scheme)
    end

    unless @connector
      redirect_to edit_tax_entity_path(@entity), alert: t("filing.invalid_scheme")
      return
    end

    # For connect and disconnect the taxpayer comes in on the URL; for the
    # scheme-driven actions it is read from the tax report group being filed.
    @taxpayer = current_admin.usable_taxpayers.find_by(id: params[:taxpayer_id])
    @filing       = Filing::Base.for(@connector, entity: @entity, scheme: @scheme,
                                          admin: current_admin, taxpayer: @taxpayer)
    # Every user-facing string on these pages names the authority. Resolved once
    # here so no view has to ask which one it is dealing with.
    @authority = @filing.authority
    # Whether this authority needs the browser to collect anything before a call
    # goes out to it. The view carries the answer as a data attribute and never
    # asks which authority it is. Asked of the CONNECTOR rather than of @filing:
    # it is a fact about the connector.
    @browser_collector = Filing::Base.connector_class(@connector)&.browser_collector
    # And the scheme's own name, for the same reason: the page shows it, and a
    # template should not have to ask a config object what it is.
    @scheme_label = TaxSchemeConfig.scheme_label(@scheme) if @scheme
  rescue ArgumentError => e
    redirect_to edit_tax_entity_path(@entity), alert: e.message
  end

  # The redirect URI sent to the authority, which must match what is REGISTERED
  # with it exactly. The path therefore comes from the connector
  # (Filing::Base.registered_callback_path), not from this controller, which
  # serves every authority and can know none of their registrations.
  #
  # NO LOCALE IN THIS URL, deliberately: HMRC's hub allows only FIVE redirect
  # URIs, so a locale segment would mean one slot per language, and the next
  # language added would break OAuth for anyone using it. The locale scope in
  # routes.rb is optional, so the route matches without one; connect stashes the
  # language in the session and callback restores it.
  #
  # "localhost" in development, also deliberately: a hub refuses a plain-http
  # redirect URI on any host but localhost, so a made-up development hostname
  # cannot be registered at all.
  def filing_callback_uri(connector = nil)
    connector ||= @connector.presence || session[:filing_oauth_type]
    path = Filing::Base.connector_class(connector)&.registered_callback_path ||
           Filing::Base.registered_callback_path

    if Rails.env.development?
      "http://localhost:#{request.port}#{path}"
    else
      "#{request.base_url}#{path}"
    end
  end
end
