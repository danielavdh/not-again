require "shrine"

if Rails.env.production?
require "shrine/storage/s3"

  # Any S3-compatible provider. The keys live in credentials under :scaleway,
  # because that is where the account they belong to was set up — the name is
  # historical, not a requirement. Set :endpoint and :region to point somewhere
  # else entirely.
  #
  # scaleway:
  # bucket:        books-receipts
  # tax_bucket:    books-filings      # falls back to "<bucket>-tax"
  # backup_bucket: books-db-backups   # optional, no fallback — see below
  # region:        fr-par
  # endpoint:      https://s3.fr-par.scw.cloud
  # access_key:    …
  # secret_key:    …
  #
  # :backup_bucket is not used by Shrine at all. It is where
  # lib/scripts/backup_db.sh uploads its nightly dumps, and naming it here lets
  # Maintenance::WeeklyCheck look at the backups themselves instead of trusting
  # that a cron job said it was fine. Deliberately no fallback: a guessed name
  # would either fail to read or — worse — read some empty bucket and report the
  # backups healthy. Left unset, the weekly report says the backups are not
  # being checked.
  unless ENV["SECRET_KEY_BASE_DUMMY"]  # in case it's docker trying to deploy
    s3_options = ObjectStorage.client_options.merge(bucket: ObjectStorage::BUCKET)

    # Kept separate from the receipts bucket so a filing archive can carry its
    # own lifecycle and access rules — it is the one thing here with a statutory
    # retention period attached.
    tax_bucket = ObjectStorage::TAX_BUCKET

    Shrine.storages = {
      cache: Shrine::Storage::S3.new(prefix: "cache", **s3_options),
      store: Shrine::Storage::S3.new(**s3_options),
      # Tax filing archive — separate private bucket, plain filename-keyed store
      # (used directly by Filing::Storage, not via an attacher).
      tax_filings: Shrine::Storage::S3.new(**s3_options.merge(bucket: tax_bucket))
    }
  end
else
require "shrine/storage/file_system"

  Shrine.storages = {
    cache: Shrine::Storage::FileSystem.new("public", prefix: "uploads/cache"),
    store: Shrine::Storage::FileSystem.new("public", prefix: "uploads"),
    # Tax filing archive — mirrors the :tax_filings S3 storage used in
    # production.
    tax_filings: Shrine::Storage::FileSystem.new("public", prefix: "tax_submissions")
  }

end

Shrine.plugin :activerecord
Shrine.plugin :cached_attachment_data # for retaining the cached file across form redisplays
Shrine.plugin :restore_cached_data # re-extract metadata when attaching a cached file

# extra plugins:
Shrine.plugin :validation
Shrine.plugin :validation_helpers  # validation logic for metadata
Shrine.plugin :determine_mime_type, analyzer: :marcel   # for secure mime_type validation
Shrine.plugin :instrumentation  # logging
Shrine.plugin :pc_partition    # sits in lib/shrine/plugins of this app
# extra plugins for backgrounding:
Shrine.plugin :backgrounding
Shrine::Attacher.promote_block do
  PromoteJob.perform_later(self.class.name, record.class.name, record.id, name.to_s, file_data)
end
Shrine::Attacher.destroy_block do
  DestroyJob.perform_later(self.class.name, data)
end



