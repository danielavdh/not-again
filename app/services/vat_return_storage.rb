# frozen_string_literal: true

# Required here for the same reason as TaxExportStorage: the gem is
# `require: false` in the Gemfile.
require "aws-sdk-s3"

# The VAT return as it was when it was marked final: the CSV the download
# button produces, kept in the tier-2 bucket (the receipts bucket, beside
# tax_exports/) under vat_returns/<report_id>/. Tier 3 keeps what was actually
# sent to an authority in its own bucket (Filing::Storage).
#
# Every finalisation adds a file; none is overwritten, so a return reopened and
# finalised again keeps both versions.
#
# The CSV's headings and number format follow whoever pressed the button, so
# two CSVs of the same figures can differ as text. The figures' fingerprint is
# therefore part of the filename, and "have the books changed since?" compares
# fingerprints, never file contents.
class VatReturnStorage
  PREFIX = "vat_returns"
  FILENAME_FORMAT = /\A\d{2}-\d{2}-\d{2}-\d{6}-\d{3}-[0-9a-f]{12}\.csv\z/

  Entry = Struct.new(:key, :finalized_at, :fingerprint, keyword_init: true) do
    def filename = File.basename(key)
  end

  def self.key_for(report_id, time, fingerprint)
    "#{PREFIX}/#{report_id}/#{time.strftime('%y-%m-%d-%H%M%S-%L')}-#{fingerprint}.csv"
  end

  def self.upload(key, csv_content)
    store.upload(StringIO.new(csv_content), key)
  end

  def self.read(key)
    file = store.open(key)
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

    keys.filter_map { |key| entry_for(key) }.sort_by(&:finalized_at).reverse
  end

  def self.latest(report_id)
    list(report_id).first
  end

  def self.entry_for(key)
    stamp, fingerprint = File.basename(key).match(/\A(\d{2}-\d{2}-\d{2}-\d{6}-\d{3})-([0-9a-f]{12})\.csv\z/)&.captures
    return nil unless stamp

    Entry.new(key: key, finalized_at: Time.strptime(stamp, "%y-%m-%d-%H%M%S-%L"),
              fingerprint: fingerprint)
  end

  # Every file under one report — used when an entity is purged.
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
