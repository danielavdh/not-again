# frozen_string_literal: true

# Required here rather than relied on from elsewhere: the gem is `require:
# false` in the Gemfile, so without this line #list raises NameError anywhere
# Zeitwerk has not already pulled it in.
require "aws-sdk-s3"

module Archives
  # Where the year-end and on-demand books CSVs live: the SAME bucket receipts
  # use (ObjectStorage::BUCKET / Shrine's :store), under archives/<scope>/.
  #
  # Two scope shapes: a family key g<id>, or a two-digit entity code. Every
  # archive covers exactly one CALENDAR YEAR for one scope, and membership
  # dating (Entity.scope_windows_for) decides which member's postings belong to
  # which scope for which days. There is no per-entity fiscal-year archive and
  # no cross-year chaining — a UK entity still CLOSES on its own fiscal year,
  # but its books are archived by calendar year like everyone else's.
  #
  # No tracking table, on purpose: the bucket prefix IS the index. Downloads are
  # proxied through the app, which works identically against Shrine's FileSystem
  # storage in dev and test.
  class Storage
    PREFIX = "archives"

    # A family key, or a two-digit entity code (Entity validates the code as
    # exactly that).
    SCOPE_KEY_FORMAT = /\A(?:g\d+|\d{2})\z/
    # Exactly what key_for writes, and nothing else.
    FILENAME_FORMAT  = /\A\d{2}-\d{2}-\d{2}-(?:year-end-)?backup\.csv\z/

    Entry = Struct.new(:key, :end_date, :year_end, keyword_init: true) do
      def year = end_date.year
    end

    # The scope an entity's archives live under RIGHT NOW. Historical scope —
    # which family it was in on some past date — comes from the membership
    # timeline, never from here.
    def self.scope_key_for(entity)
      entity.entity_group_id ? "g#{entity.entity_group_id}" : entity.code
    end

    # The entity codes one scope covers, the inverse of scope_key_for, for the
    # authorisation side (Admin#can_use_archive?). A solo scope covers just
    # itself; a family one covers every entity that was EVER a member, since a
    # departed sibling's slice is permanently in the family's archive.
    #
    # An unknown or dissolved group returns [], failing every membership check
    # rather than silently granting access.
    def self.member_codes_for(scope_key)
      return [ scope_key ] unless scope_key.start_with?("g")

      EntityGroupMembership.where(entity_group_id: scope_key.delete_prefix("g"))
                           .joins(:entity).distinct.pluck("entities.code")
    end

    # SECURITY. The archive key arrives from the URL as a wildcard segment
    # (routes.rb uses *key so the ".csv" survives format parsing), so it is
    # attacker input from end to end. Nothing from the request is ever
    # concatenated: both halves are matched against the only shapes this app
    # writes, and the key is REBUILT from them. Returns [scope_key, full_key].
    def self.parse_request_key(raw)
      scope_key, filename, *rest = raw.to_s.split("/")
      return nil unless rest.empty?
      return nil unless scope_key&.match?(SCOPE_KEY_FORMAT)
      return nil unless filename&.match?(FILENAME_FORMAT)

      [ scope_key, "#{PREFIX}/#{scope_key}/#{filename}" ]
    end

    # `year` is an Integer. A year-end archive is dated 31 Dec of that year and
    # is undeletable; an on-demand one is dated the day it was taken and is
    # deletable. Same location, different suffix, so they share the scope key.
    #
    # Whoever writes this exact key last wins — the key IS the arbitration, and
    # for a year-end archive the last write is always the most complete one.
    def self.key_for(scope_key, date_or_year, year_end: false)
      date   = date_or_year.is_a?(Integer) ? Date.new(date_or_year, 12, 31) : date_or_year
      suffix = year_end ? "year-end-backup" : "backup"
      "#{PREFIX}/#{scope_key}/#{date.strftime('%y-%m-%d')}-#{suffix}.csv"
    end

    def self.upload(key, csv_content)
      store.upload(StringIO.new(csv_content), key)
    end

    def self.read(key)
      file = store.open(key)
      file.read
    ensure
      file&.close
    end

    # Newest first.
    def self.list(scope_key)
      keys =
        if Rails.env.production?
          s3.list_objects_v2(bucket: ObjectStorage::BUCKET,
                              prefix: "#{PREFIX}/#{scope_key}/", max_keys: 1000)
            .contents.map(&:key)
        else
          Dir.glob(Rails.root.join("public", "uploads", PREFIX, scope_key, "*.csv"))
             .map { |path| "#{PREFIX}/#{scope_key}/#{File.basename(path)}" }
        end

      keys.filter_map { |key| entry_for(key) }.sort_by(&:end_date).reverse
    end

    def self.entry_for(key)
      basename = File.basename(key)
      if (date = basename[/\A(\d{2}-\d{2}-\d{2})-year-end-backup\.csv\z/, 1])
        return Entry.new(key: key, end_date: Date.strptime(date, "%y-%m-%d"), year_end: true)
      end

      date = basename[/\A(\d{2}-\d{2}-\d{2})-backup\.csv\z/, 1]
      return nil unless date

      Entry.new(key: key, end_date: Date.strptime(date, "%y-%m-%d"), year_end: false)
    end

    # Does an undeletable archive already cover this calendar year for this
    # scope? (`entries` may be passed in to avoid re-listing in a loop.)
    def self.year_end_archived?(scope_key, year, entries: nil)
      (entries || list(scope_key)).any? { |e| e.year_end && e.year == year }
    end

    def self.delete(key)
      store.delete(key)
    end

    # Every archive under one scope, for when an entity is purged. Only ever
    # called with a solo entity code, never a family key: a family's archives
    # are shared history and outlive any one member.
    def self.delete_scope(scope_key)
      store.delete_prefixed("#{PREFIX}/#{scope_key}/")
    end

    private_class_method def self.store
      Shrine.storages.fetch(:store)
    end

    private_class_method def self.s3
      @s3 ||= Aws::S3::Client.new(**ObjectStorage.client_options)
    end
  end
end
