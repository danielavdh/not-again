class WelcomeController < ApplicationController
  # The one list of which help documents exist — read by the boot guard
  # (config/initializers/00_locale_guard.rb) and by manuals_test.rb, so a
  # document that loses its English file is named as missing rather than quietly
  # dropping out of what gets checked.
  HELP_DOCS = %w[easy_manual pro_manual legal].freeze

  allow_unauthenticated_access
  # Every hit writes a Session row, so without this the demo URL is a way to
  # fill a table. The login form is capped the same way.
  rate_limit to: 10, within: 3.minutes, only: :demo_enter,
             with: -> { redirect_to demo_path, alert: t("sessions.try_later") }

  def index
  end

  # Public whether or not a demo actually exists — the page explains the idea,
  # only the button depends on there being books to show.
  def demo
  end

  # POST, not GET, because it starts a session: a GET that does this can be
  # fired by an <img> tag on somebody else's page.
  #
  # version=pro picks the demo account with journal entries switched on. Two
  # accounts rather than a toggle, because the toggle is a tick on the admin
  # page and a demo cannot save one.
  def demo_enter
    admin = demo_account(params[:version])
    return redirect_to demo_path, alert: "There is no demo on this installation." if admin.nil?

    # Someone already signed in has real books open; silently swapping their
    # session for the demo's would log them out of their own accounts.
    return redirect_to demo_path, alert: "Sign out of your own books first — the demo would replace your session." if authenticated? && !current_admin.demo?

    # Already through this door: "take me back", not a second login. Signing in
    # again leaves the previous session row behind on every press, and the sweep
    # would not collect it for an hour.
    return redirect_to landing_path_for(admin) if current_admin == admin

    # Changing doors — plain to pro, pro to receipts. The old demo session is
    # ended rather than orphaned.
    terminate_session if authenticated?

    start_new_session_for admin
    # The same rule signing in uses, not a second copy of it: an upload-only
    # demo belongs on the uploader, exactly as a real receipt helper does.
    redirect_to landing_path_for(admin)
  end

  def legal
    @title = "Legal"
    @eu_declaration = Document.find_by(kind: Document::EU_DECLARATION_OF_CONFORMITY)
    # What this INSTALL actually files with, not what the shared codebase
    # supports (Filing::Base.authorities_in_use) — so a DE/NL/CH-only install
    # stops asserting a UK filing relationship it does not have.
    @authorities_in_use = Filing::Base.authorities_in_use
    render localized_doc("legal")
  end

  def easy_manual
    render localized_doc("easy_manual")
  end

  def pro_manual
    render localized_doc("pro_manual")
  end

  # RFC 9116 security.txt, rendered (not static) so it reads CONTACT_EMAIL —
  # the one place the published address is defined. Expires self-refreshes.
  def security_txt
    body = <<~TXT
      Contact: mailto:#{CONTACT_EMAIL}
      Expires: #{1.year.from_now.utc.iso8601}
      Preferred-Languages: en, de
      Canonical: #{request.base_url}/.well-known/security.txt
    TXT
    render plain: body, content_type: "text/plain"
  end

  # A cookie, not an account setting: it is about the screen in front of you.
  # "1" forces it on, "0" forces it off even against the OS's prefers-contrast,
  # and no cookie at all follows the OS. Set from the profile page and the
  # public footer, both plain form posts, so it works with JavaScript off.
  def contrast
    case params[:on]
    when '1', '0'
      cookies[:high_contrast] = { value: params[:on], path: '/', expires: 1.year }
    else
      cookies.delete(:high_contrast, path: '/')
    end
    redirect_back fallback_location: root_path
  end

  private

  # Three accounts rather than one with a toggle: the journal-entries tick is
  # saved on the admin page and an access level is a link only an owner can
  # grant, so a visitor could not switch either for themselves.
  def demo_account(version)
    demos = Admin.where(demo: true)
    upload = AdminEntity.access_levels[:upload_receipts]

    case version
    when "receipts"
      demos.joins(:admin_entities).find_by(admin_entities: { access_level: upload })
    when "pro"
      demos.find_by(show_journal_entries: true)
    else
      demos.where.not(id: AdminEntity.where(access_level: upload).select(:admin_id))
           .find_by(show_journal_entries: false)
    end || demos.first
  end


  # One self-contained template per language in app/views/help, unless a
  # released custom Language overrides this locale with its own yml_content
  # field (Language::DOC_FIELDS).
  #
  # Falls back to English unconditionally — it does not check the English copy
  # exists either, and raises ActionView::MissingTemplate with nothing to catch
  # it if it does not. That case is guarded at boot instead
  # (config/initializers/00_locale_guard.rb).
  def localized_doc(doc)
    if (html = Language.custom_doc_html(doc, I18n.locale))
      @custom_doc      = doc
      @custom_doc_html = html
      return "help/custom_doc"
    end

    template = "help/#{doc}_#{I18n.locale}"
    template_exists?(template) ? template : "help/#{doc}_en"
  end
end
