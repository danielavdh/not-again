# Two boot-time guards for content this app cannot run without, and which both
# fail SILENTLY otherwise — nothing else here raises, so this does.
#
# Production only, same reasoning as 00_object_storage.rb: boot must fail HERE,
# loudly and immediately, not quietly succeed and leave a reader staring at
# broken text three weeks later. It also makes `kamal deploy` itself refuse to
# proceed — .kamal/hooks/pre-deploy runs bin/rails db:migrate before cutting
# over traffic, and that loads every initializer first, so a raise here means
# db:migrate never runs, the hook's set -e aborts, and the old container is
# never replaced.
#
# No SECRET_KEY_BASE_DUMMY exemption needed, unlike the object-storage check:
# these are plain files that ship in the repo and the image, not credentials
# injected at deploy time.
return unless Rails.env.production?

# config/locales/en.yml is the universal fallback — I18n.fallbacks is :en and
# raise_on_missing_translations is off everywhere — so losing it crashes
# nothing: every page just silently fills with "translation missing" text.
#
# Existence alone would not catch an emptied or truncated file: a blank YAML
# document parses to nil, and File.exist? says nothing about what is inside.
en_locale = begin
  YAML.load_file(Rails.root.join("config/locales/en.yml"), aliases: true)
rescue StandardError
  nil
end

if en_locale.blank?
  raise <<~MSG
    config/locales/en.yml is missing or empty.

    This is the universal translation fallback for every language. Losing it
    does not crash the app — it silently fills every page with
    "translation missing: ..." text instead, with nothing in the logs to say
    why. Restore the file before deploying.
  MSG
end

# Every doc in WelcomeController::HELP_DOCS needs its English template.
# WelcomeController#localized_doc falls back to English UNCONDITIONALLY for any
# other locale, and there is no further fallback if the English copy is itself
# missing: that is an unhandled ActionView::MissingTemplate, not graceful
# degradation. Other languages may lag behind English; English cannot lag behind
# itself.
#
# Deferred to after_initialize rather than run inline: WelcomeController is an
# app/ class, and Zeitwerk's main autoloader is not set up yet when
# config/initializers/*.rb load, so referencing it directly raises
# `uninitialized constant` on every real production boot. after_initialize runs
# once autoloading has finished, and still well before the app serves a request
# or db:migrate returns.
Rails.application.config.after_initialize do
  missing_docs = WelcomeController::HELP_DOCS.reject { |doc|
    Rails.root.join("app/views/help/#{doc}_en.html.erb").exist?
  }

  if missing_docs.any?
    raise <<~MSG
      Missing English help document#{'s' if missing_docs.size > 1}: #{missing_docs.join(', ')}.

      app/views/help/#{missing_docs.map { |d| "#{d}_en.html.erb" }.join(', ')}
      must exist — WelcomeController#localized_doc falls back to it
      unconditionally, and there is nothing further to fall back to.
    MSG
  end
end
