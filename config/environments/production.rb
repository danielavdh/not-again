require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in
  # config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored
  # by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }


# DO NOT set config.require_master_key = true — it breaks the image build,
# verified by building it. Rails' own require_master_key initializer calls
# credentials.key and exits 1 when it is missing, with no SECRET_KEY_BASE_DUMMY
# escape, and the build precompiles assets in production with no key on purpose
# (.dockerignore excludes config/master.key), so the flag kills every build from
# inside gem code.
#
# Nothing is lost: Kamal already refuses to deploy when RAILS_MASTER_KEY is
# absent from .kamal/secrets.

  # Serve assets from a CDN, or do not. Unset means the app serves its own,
  # which is a perfectly good way to run it — set ASSET_HOST only if there is a
  # CDN in front of it. Hostname, no scheme: "cdn.example.eu".
  config.asset_host = ENV["ASSET_HOST"].presence
  

  # Assume all access to the app is happening through a SSL-terminating reverse
  # proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and
  # secure cookies.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use
  # secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path ==
  # "/up" } } }

  config.action_mailer.perform_deliveries = true
  config.action_mailer.perform_caching = false
  # RAISE on a failed delivery. Every mail this app sends goes out from a
  # background job, so a raised error lands the job in
  # solid_queue_failed_executions and lets retry_on give it another go — where
  # swallowing it left a rejected mail with nothing in the log. A wrong From: or
  # an unauthorised sender now fails loudly.
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.delivery_method = :smtp
  # SMTP settings are filled in by config/initializers/smtp.rb — one place,
  # environment-or-credentials, shared with development.
  #
  # A mailer has no request to infer the host from: a password reset link is
  # built by a background job, hours after anyone visited anything. So this has
  # to be told, and an installation that cannot address itself should refuse to
  # boot rather than mail out links to nowhere. The exception is the image
  # build, which loads this environment to precompile assets on a machine that
  # has no idea what it will be deployed as.
  app_host = ENV["APP_HOST"].presence
  app_host ||= "example.invalid" if ENV["SECRET_KEY_BASE_DUMMY"]
  raise "APP_HOST is not set — the hostname this installation answers to, e.g. books.example.eu" if app_host.nil?

  config.action_mailer.default_url_options = { host: app_host, protocol: "https" }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-
  # identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  config.active_job.queue_adapter = :solid_queue

  # Replace the default in-process memory cache store with a durable
  # alternative.
#  config.cache_store = :solid_cache_store
  config.cache_store = :memory_store

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Active Record encryption keys, used by Taxpayer for the HMRC tokens. Rails
  # reads these from credentials on its own but NOT from the environment, so a
  # keyless, pure-ENV deploy has to wire them in here. Untouched when the vars
  # are absent, so a Kamal installation's credentials.active_record_encryption
  # keeps working as before.
  if ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present?
    config.active_record.encryption.primary_key         = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
    config.active_record.encryption.deterministic_key   = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
    config.active_record.encryption.key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
  end

end
