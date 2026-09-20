module ApplicationHelper
  def nav_link_to(text, path, options = {})
    # Check if the current request path matches the link path
    if current_page?(path)
      options[:class] = "#{options[:class]} active".strip
      options[:aria] ||= {}
      options[:aria][:current] = "page" # Good for accessibility
    end

    link_to text, path, options
  end

  # [label, code] pairs — the one shared source both language switchers read, so
  # there is exactly one place that decides what is actually offered.
  #
  # English first, always: never a Language row, never toggled off, the same
  # unconditional status it has in 00_locale_guard.rb and WelcomeController's
  # fallback. Reading only Language.cached_released silently stops offering it
  # at all. Released system and custom languages follow.
  def selectable_languages
    [ [ "English", I18n.default_locale.to_s ] ] +
      Language.cached_released.map { |code, row| [ row[:label], code ] }
  end

  def language_switcher
    links = selectable_languages.map do |label, code|
      if I18n.locale.to_s == code
        tag.span(code.upcase, class: "lang-active")
      else
        link_to(code.upcase, url_for(request.params.merge(locale: code)), class: "lang-link", title: label)
      end
    end

    safe_join(links, "·")
  end

  # Sudo only — see ApplicationController#verify_locale_is_released, which is
  # what actually makes these links work rather than 404. The suffix is
  # deliberately visible text, not a tooltip: sudo should never wonder why they
  # can see a language nobody else can.
  def draft_language_switcher
    links = Language.custom.draft.order(:code).map do |language|
      link_to("#{language.code.upcase}",
              url_for(request.params.merge(locale: language.code)), class: "lang-link lang-draft")
    end

    safe_join(links, "·")
  end

  def translated_role
    I18n.t("auth.role.#{current_login_type}", default: current_login_type).humanize
  end
  
end