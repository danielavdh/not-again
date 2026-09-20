# The languages this app is actually translated into. The switcher and every
# "does every key exist in every language" test read this list; the label is
# what the switcher shows.
LANGUAGES = [
  ['Deutsch' ,	'de' ],
  ['English' ,	'en' ],
  ['Español' ,	'es' ],
  ['Nederlands', 'nl']
]

# Locales that read right-to-left. Hebrew is not in LANGUAGES yet (no he.yml),
# but ApplicationController#text_direction already checks this list, so the HTML
# dir attribute is ready the moment it is.
RTL_LOCALES = %i[he ar].freeze

# Rails' own strings — dates, numbers, currency formats, error messages,
# activerecord — come from the rails-i18n gem, which ships a file per locale and
# loads EVERY locale it carries (~130) into I18n.load_path unconditionally.
# Verified, not assumed: I18n.t("date.month_names", locale: :fr) returns real
# French month names even though "fr" is nowhere in LANGUAGES or
# I18n.available_locales. There is no filtering step tied to either, so a sudo-
# added custom language already gets Rails' built-in strings for free.
#
# config/locales/ holds ONLY what this app says for itself. It loads AFTER the
# gem — this runs in an initializer, gems in a railtie — so where a key is set
# in both, the app wins.
I18n.load_path += Dir[
  Rails.root.join('config', 'locales', '**', '*.{rb,yml}')
]

# Whitelist of locales available to the application, DERIVED from LANGUAGES
# rather than written out again: a language in one list but not the other failed
# silently — in LANGUAGES only meant English on every key, here only meant
# reachable by URL with no way to leave it.
#
# This does NOT bound what the gem loads. Its only real job is the switcher and
# system-language list. The number-format picker needs Swiss and French
# formatting WITHOUT making them selectable UI languages, so it carries those
# few values literally rather than adding locales here.
I18n.available_locales = LANGUAGES.map { |_label, code| code.to_sym }

I18n.default_locale = :en

# Sudo-added languages are deliberately NOT added here — that would need a
# restart to take effect, exactly what the feature exists to avoid.
# I18n.with_locale raises I18n::InvalidLocale for anything outside this list by
# default; this turns that off, and
# ApplicationController#verify_locale_is_released polices the boundary instead,
# per request, against LANGUAGES plus Language.released_codes.
#
# Not the tradeoff it looks like: since the gem's data was never gated by this
# list, a sudo-added language gets this app's own strings from its own row AND
# Rails' built-in ones from the gem, both in full.
I18n.enforce_available_locales = false

# Fall back to English for any key missing in the current locale.
require 'i18n/backend/fallbacks'
I18n::Backend::Simple.include(I18n::Backend::Fallbacks)
I18n.fallbacks = I18n::Locale::Fallbacks.new(:en)
