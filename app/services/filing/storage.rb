# frozen_string_literal: true

module Filing
  # Archives tax filing submission HTML files in the :tax_filings Shrine
  # storage.
  #
  # Keyed at {entity_code}/{group}/{YY-MM-DD}-{scheme_code}-{CC}.html, where
  # group is the filing regime family ("MTD", "VAT", "EUER") and YY-MM-DD is the
  # period END date. In the cumulative model each quarter's submission covers
  # the tax year to date, so keying on the end date gives one distinct file per
  # quarterly submission — an audit trail — rather than colliding on a fixed
  # cumulative start.
  class Storage
    # The scheme code comes from `form_code:` in the scheme's own tax category
    # file, beside report_name and submission_name, which is where every other
    # name for a scheme lives — not a table of British form numbers hardcoded in
    # a generic archiver.
    #
    # The fallback is the upcased slug, so a scheme that declares no form code
    # still produces a readable, unique key.

    # The country comes from the SCHEME — an entity has none of its own, and may
    # file in more than one place.
    def self.filename_for(entity:, scheme:, period_end:, group:)
      scheme_code = TaxSchemeConfig.form_code_for(scheme).presence || scheme.to_s.upcase
      country     = TaxSchemeConfig.country_for(scheme).to_s.upcase
      "#{entity.code}/#{group}/#{period_end.strftime('%y-%m-%d')}-#{scheme_code}-#{country}.html"
    end

    def self.upload(filename, html_content)
      io = StringIO.new(html_content)
      storage.upload(io, filename)
    rescue => e
      Rails.logger.error "Filing::Storage upload failed for #{filename}: #{e.message}"
      raise
    end

    def self.fetch_html(filename)
      file = storage.open(filename)
      file.read
    ensure
      file&.close rescue nil
    end

    # Every filed document for one entity, for when the entity is purged.
    # Filings ARE code-partitioned — the key starts {entity_code}/ — so this is
    # exact and cannot reach another entity's records.
    def self.delete_all_for(entity_code)
      storage.delete_prefixed("#{entity_code}/")
    end

    private_class_method def self.storage
      Shrine.storages.fetch(:tax_filings)
    end
  end
end
