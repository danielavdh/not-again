module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?, :current_admin, :admin_signed_in?, :logged_in?, :sudo?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end

    # --- ADMIN FILTERS ---
    def require_sudo(**options)
      before_action :ensure_sudo, **options
    end

    # Any signed-in admin. On its own this only opens the accounts door — what an
    # admin may then reach is decided by their entity links (BaseController).
    def require_admin(**options)
      before_action :ensure_admin, **options
    end

    # Anything beyond keeping books — managing admins, reading the manuals. An
    # admin invited purely to keep books (read_only or upload_receipts) has no
    # business there, so "signed in as some admin" is not enough.
    def require_full_access(**options)
      before_action :ensure_full_access, **options
    end

    # Second factor for an admin session. Lives here, not in BaseController,
    # because it is the ADMIN that carries the privilege.
    def require_otp(**options)
      before_action :require_otp_verification, **options
    end

    # The terms gate. Same shape as require_otp: registered here so both
    # BaseController and AdminsController can require it.
    def require_terms(**options)
      before_action :require_terms_agreement, **options
    end

    # The claim gate. Same shape again — see #require_claim_completed.
    def require_claim(**options)
      before_action :require_claim_completed, **options
    end

  end

  private
  

    # ⚠️ NOT the same rule as OTP's exemptions. upload_receipts_only admins are
    # exempt from OTP for friction reasons (a phone, nothing more to prove) but
    # they still handle real personal data through receipts, so they are NOT
    # exempt here — see known-limitations.md §13. Demo is exempt: there is no
    # real relationship to consent to, and asking a passwordless stranger to
    # "agree to terms" for a public demo is nonsensical.
    #
    # Deliberately no "has this admin ever agreed to ANY version" shortcut —
    # bumping Admin::TERMS_VERSION must re-gate everyone, including
    # an admin who agreed to a previous version last year.
    def require_terms_agreement
      return unless current_admin&.can_access_accounts?
      return if current_admin.demo?
      # No session cache needed here, unlike OTP: terms_agreed_version is a
      # plain column on current_admin, already loaded with the rest of the
      # record for this request — checking it costs nothing extra, so there
      # is nothing to cache.
      return if current_admin.agreed_to_current_terms?

      session[:return_to_after_terms] = request.url
      redirect_to terms_path
    end

    # A coadmin created for a brand-new email (Admin#draft?) must confirm
    # their email and set a real password, in one sequence, before
    # reaching anything else — otherwise agreeing to terms or setting up
    # 2FA would happen using a password the granting full-access admin
    # chose and therefore still knows. Runs before both of those gates.
    #
    # Never fires for demo (claimed_at set directly at creation —
    # lib/tasks/demo.rake) or for an admin sudo created (create_as_sudo
    # sets claimed_at directly too) or for anything that existed before
    # the concept did (backfilled by the migration that added the
    # column) — only a genuine first-time coadmin login reaches this.
    def require_claim_completed
      return unless current_admin&.draft?

      session[:return_to_after_claim] = request.url if request.get?
      redirect_to claim_path
    end

    # --- Session Management ---

    def authenticated?
      Current.session.present?
    end

    def logged_in?
      authenticated?
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end
    def find_session_by_cookie
      Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def start_new_session_for(admin)
      admin.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        # Permanent (20 years) for an admin who wants to stay logged in — and a
        # plain browser-session cookie for a demo visitor, who did not ask to be
        # remembered and whose row SessionSweepJob deletes within two hours. A
        # permanent cookie there is a dead pointer left in a stranger's browser
        # by definition, and /demo says nothing follows them out.
        jar = admin.demo? ? cookies.signed : cookies.signed.permanent
        jar[:session_id] = {
          value: session.id,
          httponly: true,
          same_site: :lax
        }
      end
    end

    # Everything goes: the session row, the whole cookie session, and the signed
    # cookie that points at the row.
    #
    # reset_session rather than deleting keys one at a time — the cookie session
    # carries eleven things and logging out used to clear three, so login_type,
    # default_currency, last_upload_entity_id, the return_to_* pair and any
    # abandoned filing_oauth_* were left in the browser. Nobody could
    # do anything with them (the session row was gone), but we say in the privacy
    # notice that we do not keep them, and a twelfth key added later would have
    # been forgotten here too.
    #
    # This does NOT touch the HMRC connection: those tokens live on Taxpayer,
    # encrypted, and belong to the taxpayer rather than to a browser session. The
    # filing_oauth_* keys are only scratch notes for the half-minute of setting a
    # connection up.
    def terminate_session
      Current.session&.destroy
      # ⚠️ Load-bearing. Current.admin delegates to the session, so destroying the
      # row is not enough: without this, authenticated? and current_admin keep
      # answering yes for the rest of the request. Matters wherever this is followed
      # by a render rather than a redirect.
      Current.session = nil
      reset_session
      cookies.delete(:session_id)
    end

    # --- Current Admin ---

    def current_admin
      Current.admin
    end

    def admin_signed_in?
      current_admin.present?
    end

    def sudo?
      current_admin&.sudo? || false
    end

    # Shared by every controller that is sudo's alone — AdminsController#index,
    # LanguagesController — rather than each one spelling out the same redirect.
    def require_sudo_only
      redirect_to dashboard_path, alert: "Access denied" unless sudo?
    end

    # --- Authentication Filters ---

    def require_authentication
      resume_session || request_authentication
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      #redirect_to new_session_path(request.query_parameters.merge(locale: I18n.locale))
      redirect_to new_session_path(request.query_parameters)
    end
    
    # root_url is the PUBLIC front page, so it is not where signing in should
    # land you — the dashboard is.
    def after_authentication_url
      session.delete(:return_to_after_authenticating) || dashboard_url
    end
    
    # --- Authorization Filters ---
    
    # Signed in and simply not allowed is a REFUSAL, not a login: the login form
    # reads as "you were logged out", which is untrue. Only someone with no session
    # is offered it.
    #
    # ⚠️ Do not turn this back into redirect_to_login. /login deliberately ends a
    # demo session (SessionsController#new), so a demo following a sudo-only link
    # would be thrown out of the demo by the refusal itself.
    def ensure_sudo
      return if sudo?
      return redirect_to_login unless admin_signed_in?

      redirect_to dashboard_path, alert: I18n.t("admins.access_denied")
    end
    def ensure_admin
      redirect_to_login unless admin_signed_in?
    end
    # sudo, or an admin holding full access to at least one entity. Deliberately
    # NOT sudo-only: a business owner keeps their own books here. What it keeps
    # out is the invited co-admin, who can only ever be read_only or
    # upload_receipts (AdminsController#create_as_full_access_admin).
    def ensure_full_access
      return if sudo?
      return if admin_signed_in? && current_admin.full_access?
      # The demo may READ the pages full access opens — the profile page is one
      # of the more interesting things in the app — and may still write nothing.
      # demo_may_look? is false for anything that is not a plain GET.
      return if admin_signed_in? && current_admin.demo? && demo_may_look?
      # Nobody is signed in as an admin — offer the login rather than a refusal.
      return redirect_to_login unless admin_signed_in?

      redirect_to dashboard_path, alert: I18n.t("admins.access_denied")
    end

    # Production-only, and skipped for upload-receipts-only admins on purpose:
    # they are people who photograph a receipt and send it, nothing more, and a
    # TOTP app is beyond what can be asked of them. They can reach nothing but
    # the standalone uploader.
    def require_otp_verification
      return unless Admin.otp_required?
      return unless current_admin&.can_access_accounts?
      return if current_admin.upload_receipts_only?
      # A stranger walking into the public demo has no second factor to offer,
      # and nothing to protect: the account is read-only on one made-up entity.
      # Exempting it here rather than weakening otp_required? keeps the rule for
      # every account that holds real books.
      return if current_admin.demo?

      return redirect_to_otp(t("access.setup_2fa")) unless current_admin.otp_configured?

      verified = session[:otp_verified]
      fresh =
        verified.is_a?(Hash) &&
        verified["admin_id"] == current_admin.id &&
        verified["at"].to_i >= 36.hours.ago.to_i

      if fresh
        # Sliding window: an admin who keeps working is never re-challenged; one
        # who goes away for a day and a half is. Deliberate (2026-08-15).
        session[:otp_verified]["at"] = Time.current.to_i
      elsif verified.is_a?(Hash) && verified["admin_id"] == current_admin.id
        # There WAS a verification for this admin and it has run out. The proof
        # died, so the session dies with it: one lifetime instead of two. Until
        # now a session outlived its own proof — it stayed valid and merely
        # re-challenged, so a stolen cookie past the window still needed a TOTP
        # code and never the password.
        #
        # terminate_session first: it calls reset_session, and redirect_to_login
        # writes its return path afterwards, so the way back survives the wipe.
        terminate_session
        redirect_to_login(t("errors.session_expired"))
      else
        # Never verified in this session: someone who has just signed in, or has
        # come back with a closed browser behind them. That is the challenge
        # this gate exists for and NOT an expiry — evicting here would log every
        # admin out at the instant they arrived, and nobody could sign in at all.
        redirect_to_otp
      end
    end

    # A demo visitor leaves no trace anywhere. They create nothing, they upload
    # nothing, and they never log out — so the session row is the only evidence
    # they were ever here, and SessionSweepJob has nothing else to read.
    #
    # Only the demo. An upload-only helper leaves receipts, which say the same
    # thing without a write on every page view, and everybody else is
    # re-challenged by OTP and needs no sweeping at all.
    #
    # At most one UPDATE a minute per session.
    def touch_demo_session
      row = Current.session
      return if row.nil?
      return if row.updated_at > 1.minute.ago
      return unless row.admin.demo?

      row.touch
    end

    def redirect_to_otp(alert = nil)
      session[:return_to_after_otp] = request.url
      redirect_to otp_path, alert: alert
    end
    def redirect_to_login(alert = nil)
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path, alert: alert
    end

end

