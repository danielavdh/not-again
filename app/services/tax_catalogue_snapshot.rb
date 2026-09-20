# frozen_string_literal: true

# A record of where every tax category currently files its figure, so that
# changing one has to be deliberate.
#
# The loader upserts by (country, scheme, year, key), so editing a category's
# export_column or api_field MUTATES the existing row — same id, new destination
# — and a report re-run over an already-filed period then resolves against the
# new box. Nothing raises, nothing is logged, and the record of where 2026's
# figures went is gone.
#
# Removing a key is caught at runtime, because rows are deleted and
# TaxCategoryRemovalNotificationJob emails the affected bookkeepers. Mutation
# cannot be: by the time the loader runs, the old value is already overwritten.
# So it is caught earlier — in a test, on the file itself, before it reaches any
# database.
#
# Only the fields that decide WHERE a figure is filed are recorded. A label, a
# note or a position can be corrected freely; those change how a box reads, not
# what it does.
class TaxCatalogueSnapshot
  DIR  = Rails.root.join("db", "tax_categories")
  # NOT in test/fixtures: everything there is loaded as a DATABASE fixture, and
  # Rails duly tried to insert this into a table called tax_catalogue_snapshot.
  # It lives beside the catalogues it describes instead, outside the *.yml glob
  # the loader reads.
  PATH = Rails.root.join("db", "tax_catalogue_snapshot.yml")

  # section     — income / expenses / other, and so which total a figure joins
  # api_section — where a submission files it, when that differs from section
  # export_column — the authority's own box identifier
  # api_field   — the field a digital submission sends
  FILING_FIELDS = %w[section api_section export_column api_field].freeze

  class << self
    def current
      Dir[DIR.join("*.yml").to_s].sort.each_with_object({}) do |path, out|
        data = YAML.safe_load_file(path, permitted_classes: [Symbol])
        next unless data.is_a?(Hash) && data["categories"].is_a?(Array)

        out[File.basename(path)] = data["categories"].each_with_object({}) do |row, cats|
          next unless row.is_a?(Hash) && row["key"].present?
          cats[row["key"].to_s] = FILING_FIELDS.index_with { |f| row[f]&.to_s }
        end
      end
    end

    def recorded
      return {} unless PATH.exist?
      YAML.safe_load_file(PATH) || {}
    end

    def write!
      PATH.dirname.mkpath
      PATH.write(<<~HEADER + current.to_yaml.sub(/\A---\n/, ""))
        # Where every tax category files its figure. Generated — do not hand-edit:
        #
        #   bin/rails tax_categories:snapshot
        #
        # TaxCatalogueSnapshotTest fails when a catalogue file disagrees with
        # this. That is the point: editing a filing field in place rewrites history,
        # because the loader upserts the SAME row and an already-filed period then
        # resolves against the new box.
        #
        # If the AUTHORITY changed something, do not update this file — add a new
        # year file and leave the old one alone. Update this only when WE were
        # wrong, and commit it alongside the correction.
      HEADER
    end

    # [ [file, key, field, was, now], ... ] — every filing field that moved.
    def changes
      now = current
      was = recorded

      (was.keys & now.keys).flat_map do |file|
        (was[file].keys & now[file].keys).flat_map do |key|
          FILING_FIELDS.filter_map do |field|
            before = was[file][key][field].presence
            after  = now[file][key][field].presence
            [file, key, field, before, after] if before != after
          end
        end
      end
    end

    # [ [file, key], ... ] — keys the snapshot knows that the file no longer
    # has.
    def removals
      now = current
      was = recorded
      (was.keys & now.keys).flat_map do |file|
        (was[file].keys - now[file].keys).map { |key| [file, key] }
      end
    end

    def new_keys
      now = current
      was = recorded
      (was.keys & now.keys).flat_map do |file|
        (now[file].keys - was[file].keys).map { |key| [file, key] }
      end
    end
  end
end
