# frozen_string_literal: true

# The checkpoints a signed-in admin passes before reaching the app: the second
# factor, the terms, and claiming a draft account.
class GatesController < BaseController
  CLAIM_ACTIONS = [ :claim_show, :claim_update, :claim_resend ].freeze

  OTP_ACTIONS = [ :otp_show, :otp_verify, :otp_confirm ].freeze

  skip_before_action :require_otp_verification, only: OTP_ACTIONS + CLAIM_ACTIONS
  # ⚠️ OTP_ACTIONS here too, and it is not optional.
  #
  # BaseController runs the gates in order: claim, then OTP, then terms. So a
  # brand-new admin is sent to /otp by the OTP gate — and if the terms gate
  # still applied there, /otp would bounce to /terms, /terms would bounce back
  # to /otp (it does not skip the OTP gate), and nobody could ever finish a
  # first login. ERR_TOO_MANY_REDIRECTS, on a live server, for every new
  # account.
  #
  # Invisible in test and development: Admin.otp_required? is
  # Rails.env.production?, so the OTP gate never fires there and the loop
  # cannot form. See the guard in test/integration/otp_gate_test.rb, which
  # forces otp_required? true for exactly this reason.
  skip_before_action :require_terms_agreement,  only: [ :terms_show, :terms_agree ] + OTP_ACTIONS + CLAIM_ACTIONS
  # Agreeing to terms and claiming an account are not book writes, so an upload-
  # only or read-only admin must be able to reach them like anyone else.
  skip_before_action :require_write_access,     only: [ :terms_show, :terms_agree ] + CLAIM_ACTIONS
  # The claim gate is what SENT them here — reaching it again would loop.
  skip_before_action :require_claim_completed,  only: CLAIM_ACTIONS
  # Must still be a draft: otherwise claim_update would silently replace a
  # claimed admin's own password, with none of the confirmation
  # PasswordsController requires.
  before_action :ensure_still_a_draft, only: CLAIM_ACTIONS

  # Keyed by admin, not IP, unlike every other rate_limit in the app. Reaching
  # otp_verify means the password was already correct, so what is worth limiting
  # is guesses against this account — a distributed attempt rotating IPs would
  # sail through an IP-keyed limit.
  rate_limit to: 10, within: 3.minutes, only: :otp_verify, by: -> { current_admin&.id },
    with: -> { flash.now[:alert] = t("gates.otp_verify.rate_limited"); render :otp_verify, status: :too_many_requests }

  # GET /otp - verify form (if already set up) or setup form (if not)
  def otp_show
    if current_admin.otp_secret.present?
      render :otp_verify
    else
      generate_new_secret
      render :otp_setup
    end
  end

  # POST /otp/verify
  def otp_verify
    totp = ROTP::TOTP.new(current_admin.otp_secret, issuer: "Accounts")
    if totp.verify(params[:otp_code], drift_behind: 15, drift_ahead: 15)
      mark_otp_verified!
      redirect_to after_otp_url, notice: t("gates.otp_verified"), allow_other_host: true
    else
      # Reaching here means the password was right and only the second factor
      # stood in the way: somebody holds a working password. This is the entry
      # the table exists for.
      SignInEvent.record(outcome: :otp_failed, username: current_admin.username,
                         request: request, admin: current_admin)
      flash.now[:alert] = t("gates.otp_verify.invalid")
      render :otp_verify, status: :unprocessable_entity
    end
  end

  # POST /otp/setup
  def otp_confirm
    totp = ROTP::TOTP.new(params[:otp_secret], issuer: "Accounts")
    if totp.verify(params[:otp_code], drift_behind: 15, drift_ahead: 15)
      current_admin.update!(otp_secret: params[:otp_secret], otp_enabled: true)
      mark_otp_verified!
      redirect_to after_otp_url, notice: t("gates.otp_enabled"), allow_other_host: true
    else
      generate_new_secret
      flash.now[:alert] = t("gates.otp_setup.invalid")
      render :otp_setup, status: :unprocessable_entity
    end
  end

  # GET /terms
  def terms_show
    @version = Admin::TERMS_VERSION
  end

  # POST /terms/agree
  # Plain columns, so a double-submitted form is two identical updates and needs
  # no rescue.
  def terms_agree
    current_admin.update!(terms_agreed_version: Admin::TERMS_VERSION, terms_agreed_at: Time.current)

    AdminMailer.with(
      admin: current_admin,
      version: Admin::TERMS_VERSION,
      locale: I18n.locale
    ).terms_agreed.deliver_later

    redirect_to session.delete(:return_to_after_terms) || dashboard_path
  end

  # GET /claim — decides which half of the flow to show: "check your email"
  # while unverified, the set-a-password form once it is. The order is enforced
  # by verified_at rather than a second column, since it already means exactly
  # "clicked the link".
  def claim_show
  end

  # PATCH /claim — the password half. Requires verified_at first: nothing about
  # setting a password depends on it technically, but a crafted PATCH must not
  # skip ahead of confirming the email.
  def claim_update
    unless current_admin.verified?
      redirect_to claim_path, alert: t("gates.claim.verify_first")
      return
    end

    if current_admin.update(params.permit(:password, :password_confirmation))
      current_admin.claim!
      redirect_to session.delete(:return_to_after_claim) || dashboard_path,
                  notice: t("gates.claim.claimed")
    else
      render :claim_show, status: :unprocessable_entity
    end
  end

  # POST /claim/resend — email_verification expires in 24 hours but a draft
  # survives up to a month (Admins::DraftSweepJob), so a stale inbox link is the
  # ordinary case, not a mistake.
  def claim_resend
    AdminMailer.with(admin: current_admin, locale: I18n.locale).email_verification.deliver_later
    redirect_to claim_path, notice: t("gates.claim.resent")
  end

  private

  def ensure_still_a_draft
    redirect_to dashboard_path unless current_admin.draft?
  end

  def generate_new_secret
    @otp_secret = ROTP::Base32.random
    totp = ROTP::TOTP.new(@otp_secret, issuer: "Accounts")
    @qr_code = RQRCode::QRCode.new(totp.provisioning_uri(current_admin.email_address))
                              .as_svg(module_size: 4, viewbox: true)
  end

  def mark_otp_verified!
    session[:otp_verified] = { "admin_id" => current_admin.id, "at" => Time.current.to_i }
    session.delete(:otp_verified_at) # drop the legacy key
  end

  # The stored target may be on the main host, so it is a full URL. Anything
  # that is not one of our own hosts is discarded rather than followed — it
  # arrives via the session, and an open redirect is not worth the convenience.
  def after_otp_url
    target = session.delete(:return_to_after_otp)
    return dashboard_path if target.blank?

    host = begin
      URI.parse(target).host
    rescue URI::InvalidURIError
      nil
    end
    return dashboard_path if host.blank? || !host.end_with?(request.domain)

    target
  end
end
