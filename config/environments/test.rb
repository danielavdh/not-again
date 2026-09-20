
Rails.application.configure do
  # Active Record encryption keys, fixed and fake.
  #
  # AR encryption raises outright when its keys are missing — unlike every other
  # credentials lookup in this app, which uses .dig and returns nil. That one
  # difference meant the whole suite needed config/master.key, and therefore CI
  # did, and therefore a Dependabot workflow run could read the key that
  # decrypts the Scaleway credentials, and so the receipts bucket and the
  # database backups.
  #
  # These are not secrets. They exist so tests can round-trip an encrypted
  # column against data that is thrown away.
  config.active_record.encryption.primary_key            = "test-only-primary-key-not-a-secret-000000"
  config.active_record.encryption.deterministic_key      = "test-only-deterministic-key-not-secret-00"
  config.active_record.encryption.key_derivation_salt    = "test-only-derivation-salt-not-a-secret-00"

  # Settings specified here will take precedence over those in
  # config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store
  
  config.action_mailer.delivery_method = :test
  config.action_mailer.default_url_options = { host: "www.example.com" }

  # Render exception templates for rescuable exceptions and raise for other
  # exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Matches production — see config/environments/development.rb for why.
  config.i18n.fallbacks = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing
  # actions.
  config.action_controller.raise_on_missing_callback_actions = true
  
  config.active_job.queue_adapter = :test
  
  Shrine.logger.level = Logger::WARN
end
