class SessionsController < ApplicationController
  # :destroy too — asking to leave when you are already out is no reason to be
  # asked for a password. terminate_session is safe with no session and CSRF
  # still applies, so nobody can be logged out from somewhere else.
  allow_unauthenticated_access only: %i[ new create destroy ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: t("sessions.try_later") }
  before_action :set_title
  layout 'accounting'

  # A live session skips the form rather than asking again for a password it
  # does not need. A demo session is the exception: a demo visitor is signed in
  # but not as themselves, so the demo session ends here and a stranger gets the
  # form.
  #
  # A destructive GET, safe only because nothing redirects here for a refusal
  # (Authentication#ensure_sudo). Keep it that way.
  def new
    return terminate_session if authenticated? && current_admin.demo?

    redirect_to landing_path_for(current_admin) if authenticated?
  end

  # The identifier accepts a username OR an email address; both are unique, so
  # the only question is which column to look the value up in. The "@" check
  # routes between two authenticate_by calls and is never itself the true/false
  # answer — authenticate_by stays the single timing-safe check, and a wrong
  # identifier and a wrong password produce the same reply either way.
  def create
    identifier = params[:username].to_s
    admin = if identifier.include?("@")
      Admin.authenticate_by(email_address: identifier, password: params[:password].to_s)
    else
      Admin.authenticate_by(username: identifier, password: params[:password].to_s)
    end
    unless admin
      # ⚠️ One message for both a wrong password and an unknown username — the
      # distinction goes in the table, never in the reply.
      SignInEvent.record(outcome: :failed, username: params[:username], request: request)
      return redirect_to new_session_path, alert: t("sessions.wrong")
    end

    SignInEvent.record(outcome: :signed_in, username: params[:username], request: request, admin: admin)

    start_new_session_for admin
    get_default_currency(admin)
    admin.update_column(:last_seen, Time.current)

    redirect_to landing_path_for(admin)
  end

  def destroy
    terminate_session
    redirect_to root_path, status: :see_other
  end

  def set_title
    @title = "Login"
  end
  
  private

  def get_default_currency(admin)
    scope = Account.active.where(account_type: [:asset, :liability, :equity])
    unless admin.sudo?
      codes = admin.entity_codes
      scope = scope.for_entity_codes(codes) if codes.any?
    end
    session[:default_currency] = scope.group(:currency)
        .order(Arel.sql('COUNT(*) DESC'))
        .limit(1)
        .pick(:currency) || 'EUR'
  end

end
