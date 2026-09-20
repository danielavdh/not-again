# frozen_string_literal: true

# ONE place that reads the object-storage settings — the endpoint was once
# written out in four: shrine.rb, the CSP initializer, Maintenance::WeeklyCheck
# and backup_db.sh. Four copies of a URL that has to agree with itself is three
# chances for receipts to load in development and be refused by the policy in
# production.
#
# Loaded first (the 00_ prefix) because initializers run in alphabetical order
# and content_security_policy.rb needs these values at boot.
#
# The settings come from two places, and the environment wins:
#
# · credentials `s3:`, falling back to `scaleway:` — the original name, kept
# working so existing Kamal installations need no edit
# · the S3_* environment variables — for a deploy with no master key, where
# credentials cannot be edited
#
# Neither name obliges you to that provider: set :endpoint and :region and
# anything speaking the S3 API will do.
module ObjectStorage
  # Credentials are unreadable during `docker build`, which runs with a dummy
  # key and no master.key. Returning empty there lets the image build; the real
  # values arrive at boot on the server.
  SETTINGS = begin
    creds = Rails.application.credentials
    from_creds = (creds.s3 || creds.scaleway || {}) unless ENV["SECRET_KEY_BASE_DUMMY"]
    from_env = {
      bucket:        ENV["S3_BUCKET"],
      tax_bucket:    ENV["S3_TAX_BUCKET"],
      backup_bucket: ENV["S3_BACKUP_BUCKET"],
      region:        ENV["S3_REGION"],
      endpoint:      ENV["S3_ENDPOINT"],
      access_key:    ENV["S3_ACCESS_KEY"],
      secret_key:    ENV["S3_SECRET_KEY"]
    }.compact_blank
    (from_creds || {}).merge(from_env)
  rescue StandardError
    nil
  end.freeze || {}.freeze

  ENDPOINT   = (SETTINGS[:endpoint].presence || "https://s3.fr-par.scw.cloud").freeze
  REGION     = SETTINGS[:region].freeze
  ACCESS_KEY = SETTINGS[:access_key].freeze
  SECRET_KEY = SETTINGS[:secret_key].freeze

  # Receipts and their thumbnails. Everything else is optional.
  BUCKET = SETTINGS[:bucket].freeze

  # Submitted returns, kept apart so the archive can carry its own retention
  # rules. Falls back to "<bucket>-tax", which must then exist.
  TAX_BUCKET = (SETTINGS[:tax_bucket].presence || (BUCKET && "#{BUCKET}-tax")).freeze

  # Database dumps. No fallback on purpose: a guessed name could read some empty
  # bucket and report that the backups are healthy. Unset means "not checked".
  BACKUP_BUCKET = SETTINGS[:backup_bucket].presence.freeze

  # The bucket's own origin, virtual-hosted style. Must match how Shrine builds
  # URLs (force_path_style: false), or receipts pass in development and fail the
  # content-security policy in production.
  def self.bucket_origin(bucket = BUCKET)
    return nil if bucket.blank?

    ENDPOINT.sub(%r{\Ahttps?://}, "https://#{bucket}.")
  end

  def self.client_options
    { region: REGION, endpoint: ENDPOINT, access_key_id: ACCESS_KEY,
      secret_access_key: SECRET_KEY, force_path_style: false }
  end
end

# Filesystem storage must NEVER be reachable in production — not as a fallback,
# not under any future refactor. If it silently were, uploads would be
# unauthenticated and gone on the next `kamal deploy`: nothing mounts
# public/uploads as a volume, so it is ordinary container filesystem, wiped the
# moment a fresh image replaces it.
#
# So production is S3, unconditionally, and if the credentials are missing, boot
# must fail HERE — loudly, immediately, with a message that says what to do —
# not quietly succeed and fail three weeks later on someone's first receipt
# upload.
#
# That is also what makes `kamal deploy` refuse to proceed without working
# credentials, with no Kamal-side tooling: pre-deploy runs db:migrate, which
# loads every initializer first, so a raise here aborts the hook and the old
# container is never replaced.
#
# SECRET_KEY_BASE_DUMMY is exempted because it is set exactly once, by
# Dockerfile during assets:precompile at BUILD time — before the real server
# exists, let alone credentials to check. Raising there breaks the image build
# itself, not a deploy.
if Rails.env.production? && !ENV["SECRET_KEY_BASE_DUMMY"] && ObjectStorage::BUCKET.blank?
  raise <<~MSG
    S3 object storage is not configured for production.

    Either set credentials.s3 (or credentials.scaleway) — bucket, region,
    endpoint, access_key, secret_key — with `bin/rails credentials:edit`, or set
    the S3_BUCKET / S3_REGION / S3_ENDPOINT / S3_ACCESS_KEY / S3_SECRET_KEY
    environment variables. Then deploy again. See docs/provider-setup.md.

    Filesystem storage is never used in production, even as a fallback: it is
    unauthenticated and does not survive a redeploy.
  MSG
end
