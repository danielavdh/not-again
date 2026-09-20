class ApplicationController < ActionController::Base
  # language needs to be first thing that runs!!
  around_action :switch_locale
  include Authentication
  before_action :resume_session
  # Must run after resume_session: it checks sudo?, which reads current_admin,
  # which resume_session is what populates. Registered earlier, sudo's preview
  # of a draft language always 404s.
  before_action :verify_locale_is_released
  before_action :touch_demo_session
  # Carry the admin's number-format choice for the request, so CurrencyConfig
  # and the JS both honour it without every call site threading it through.
  before_action { Current.number_format = current_admin&.preferred_number_format }
  # Only allow modern browsers supporting webp images, web push, badges, import
  # maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
  helper_method :current_login_type, :back_to_referer_path, :demo_available?, :demo_admin?, :contrast_class, :service_host, :text_direction
  
  rescue_from ActionController::InvalidAuthenticityToken do
    redirect_to new_session_path, alert: t("errors.session_expired")
  end

  private

  # The demo may look at everything and change nothing — wider than read_only
  # deliberately, because a demo that cannot open the entry forms is not showing
  # the app.
  #
  # "Anything that only looks" is not "any GET": #connect and #callback open an
  # OAuth conversation with a real tax authority over GET, so they are refused
  # along with the writes.
  FILING_ACTIONS = %w[connect callback disconnect periods submit report view].freeze

  def demo_may_look?
    # The demo check is the first line deliberately. Below it, deny_write
    # returns early for every admin on a GET, which let a mixed-access admin
    # open the edit form for an entity they may not write to.
    return false unless demo_admin?
    return false unless request.get?
    return false if controller_name == "filing" || FILING_ACTIONS.include?(action_name)

    true
  end

  def demo_admin?
    current_admin&.demo?
  end

  # Shared by signing in and by arriving with a session already open, so the two
  # cannot drift apart.
  def landing_path_for(admin)
    # Someone who only photographs receipts goes straight to the uploader; they
    # can reach nothing else.
    return upload_standalone_receipts_path if admin.upload_receipts_only?
    # An admin with no accounts access yet belongs here, not on the dashboard:
    # the dashboard trips require_accounts_access and terminates the session on
    # the spot.
    return admin_path(admin) unless admin.can_access_accounts?

    dashboard_path
  end

  # APP_HOST is canonical — the same value mail links are built from. The
  # request's own host is the fallback in development, where APP_HOST is not
  # set.
  def service_host
    ENV["APP_HOST"].presence || request.host
  end

  # Class for <html>, so the palette on :root can be swapped wholesale.
  #
  # Three states, not two: no cookie means "follow the system", so an explicit
  # choice has to be able to refuse prefers-contrast: more as well as ask for it
  # — which a boolean cannot express.
  def contrast_class
    case cookies[:high_contrast]
    when "1" then "high-contrast"
    when "0" then "contrast-normal"
    end
  end
  
  def text_direction
    return "rtl" if RTL_LOCALES.include?(I18n.locale)

    Language.cached_released&.dig(I18n.locale.to_s, :rtl) ? "rtl" : "ltr"
  end

  # A fresh clone has no demo admin, so /demo offers no way in and the landing
  # page hides the button. bin/rails demo:seed opens that door, never the
  # default.
  def demo_available?
    return @demo_available if defined?(@demo_available)

    @demo_available = Admin.exists?(demo: true)
  end

  # "Back to wherever you came from", for pages reachable from anywhere and so
  # having no one place to return to.
  #
  # Same-origin only: the referer is whatever the browser chose to send, so
  # without the check a link from another site would point our own back button
  # at theirs.
  #
  # Falls back to the given path, the dashboard when signed in, the front page
  # otherwise.
  def back_to_referer_path(fallback = nil)
    referer = request.referer.presence
    return referer if referer && URI.parse(referer).host == request.host

    fallback || (authenticated? ? dashboard_path : root_path)
  rescue URI::InvalidURIError
    fallback || root_path
  end

  def switch_locale(&action)
    locale = params[:locale] || I18n.default_locale
    # A custom language's strings live in Language#yml_content, not a file
    # I18n.load_path can see, so they are pushed into the backend here — before
    # the with_locale below, which is what actually looks strings up.
    Language.load_if_stale
    I18n.with_locale(locale, &action)
  end

  # The routes constraint is only /[a-z]{2}/, so this is the actual gate: a code
  # that is neither shipped nor a released Language 404s here before reaching
  # any action.
  #
  # English is checked by itself rather than via LANGUAGES. de/es/nl/ar are in
  # LANGUAGES so the rails-i18n gem keeps loading their built-in data, so
  # testing membership here would let them through before their Language row's
  # released? status was ever consulted — unticking system "es" would do
  # nothing.
  def verify_locale_is_released
    return if params[:locale].blank?
    return if params[:locale] == I18n.default_locale.to_s
    return if Language.released_codes.include?(params[:locale])
    # Sudo previews a draft before releasing it — the whole point of the
    # review step. Nobody else may pass here on an unreleased code.
    return if sudo? && Language.custom.draft.exists?(code: params[:locale])

    raise ActionController::RoutingError, "Unknown locale: #{params[:locale]}"
  end
  # ensures the locale persists in links
  def default_url_options
    { locale: I18n.locale }
  end
  
  # Vestigial: always "admin". Kept only because views and locale keys still ask
  # for it.
  def current_login_type
    "admin"
  end

end
