# frozen_string_literal: true

# Required here rather than relied on from elsewhere, the same reason as
# Archives::Storage: the gem is `require: false` in the Gemfile, so without this
# line #list raises NameError anywhere Zeitwerk has not already pulled it in.
require "aws-sdk-s3"

# Where a tax report's export backups live: the SAME bucket receipts and books
# archives use, under tax_exports/<report_id>/ — its own prefix, not archives/,
# because the two are different data with different natural keys.
#
# Insurance against the problem accounts already have without a foreign key: an
# account is tagged by plain string, so reassigning it later changes what an OLD
# report resolves to when reopened (see the TODO on TaxCategory.resolve). This
# does not prevent that — it guarantees that whatever was actually emailed on
# export day is still retrievable, the tier-2 equivalent of what Filing::Storage
# does for a filed submission.
#
# TaxExportJob only writes when the generated CSV differs from the most recent
# one on file, or re-exporting unchanged figures a hundred times would leave a
# hundred identical files. Keyed to the second, not the day: two genuinely
# different exports on one calendar day — export, reassign an account, export
# again — must not collide and silently overwrite one another.
#
# Unlike Archives::Storage this needs no attacker-proof key parsing: a report
# has its own access control, so the controller authorises the REPORT first and
# the key is always rebuilt from a trusted report id plus a filename already
# checked against FILENAME_FORMAT.
class TaxExportStorage
  PREFIX = "tax_exports"
  FILENAME_FORMAT = /\A\d{2}-\d{2}-\d{2}-\d{6}-\d{3}-[0-9a-f]{6}-backup\.csv\z/

  Entry = Struct.new(:key, :generated_at, keyword_init: true)

  # Millisecond resolution, not just seconds: two exports in the same SECOND — a
  # double-click, or a fast test — need a correctly-ordered "which one is
  # latest", and #latest_content picks the wrong entry if ties can only be
  # broken arbitrarily. The random suffix is collision insurance for the still-
  # possible same-millisecond case and plays no part in ordering.
  def self.key_for(report_id, time)
    "#{PREFIX}/#{report_id}/#{time.strftime('%y-%m-%d-%H%M%S-%L')}-#{SecureRandom.hex(3)}-backup.csv"
  end

  def self.upload(key, csv_content)
    store.upload(StringIO.new(csv_content), key)
  end

  def self.read(key)
    file = store.open(key)
    # Shrine hands back bytes as ASCII-8BIT, so comparing against the freshly
    # generated UTF-8 CSV would be false on the first em dash, defeating dedupe
    # for every scheme's header text.
    file.read.force_encoding(Encoding::UTF_8)
  ensure
    file&.close
  end

  # Newest first.
  def self.list(report_id)
    keys =
      if Rails.env.production?
        s3.list_objects_v2(bucket: ObjectStorage::BUCKET,
                            prefix: "#{PREFIX}/#{report_id}/", max_keys: 1000)
          .contents.map(&:key)
      else
        Dir.glob(store.directory.join(PREFIX, report_id.to_s, "*.csv"))
           .map { |path| "#{PREFIX}/#{report_id}/#{File.basename(path)}" }
      end

    keys.filter_map { |key| entry_for(key) }.sort_by(&:generated_at).reverse
  end

  def self.entry_for(key)
    basename = File.basename(key)
    stamp = basename[/\A(\d{2}-\d{2}-\d{2}-\d{6}-\d{3})-[0-9a-f]{6}-backup\.csv\z/, 1]
    return nil unless stamp

    Entry.new(key: key, generated_at: Time.strptime(stamp, "%y-%m-%d-%H%M%S-%L"))
  end

  # What a new export is compared against before deciding to write one —
  # nil the first time this report is ever exported.
  def self.latest_content(report_id)
    entry = list(report_id).first
    return nil unless entry
    read(entry.key)
  end

  # Every backup under one report — used when an entity is purged.
  def self.delete_report(report_id)
    store.delete_prefixed("#{PREFIX}/#{report_id}/")
  end

  private_class_method def self.store
    Shrine.storages.fetch(:store)
  end

  private_class_method def self.s3
    @s3 ||= Aws::S3::Client.new(**ObjectStorage.client_options)
  end
end
