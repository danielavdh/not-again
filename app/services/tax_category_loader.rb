# frozen_string_literal: true

class TaxCategoryLoader
  REQUIRED_HEADER_KEYS = %w[country_code scheme tax_year].freeze
  REQUIRED_ROW_KEYS    = %w[key].freeze
  ALLOWED_ROW_KEYS     = %w[key section api_section label export_column api_field position notes keywords].freeze

  def self.call(path) = new(path).call

  def initialize(path)
    @path = path
  end

  def call
    data = YAML.safe_load_file(@path, permitted_classes: [Symbol])
    raise "Root must be a Hash in #{@path}" unless data.is_a?(Hash)

    header = data.slice(*REQUIRED_HEADER_KEYS)
    REQUIRED_HEADER_KEYS.each do |k|
      raise "Missing '#{k}' in #{@path}" if header[k].to_s.empty?
    end

    categories = data['categories']
    raise "Missing 'categories:' array in #{@path}" unless categories.is_a?(Array)

    country_code = header['country_code'].to_s.downcase
    # The stored identifier is the SLUG, not the bare header word, matching
    # TaxSchemeConfig everywhere else: always "#{country_code}_#{scheme}",
    # globally unique by construction, never a bare word a contributor had to
    # remember to prefix.
    scheme       = "#{country_code}_#{header['scheme']}"
    tax_year     = header['tax_year'].to_i

    seen_keys = Set.new
    rows = categories.each_with_index.map do |row, i|
      raise "Category #{i} must be a Hash in #{@path}" unless row.is_a?(Hash)
      unknown = row.keys - ALLOWED_ROW_KEYS
      raise "Category #{i} has unknown keys: #{unknown.inspect} in #{@path}" if unknown.any?
      REQUIRED_ROW_KEYS.each do |k|
        raise "Category #{i} missing '#{k}' in #{@path}" if row[k].to_s.empty?
      end
      key = row['key'].to_s
      raise "Duplicate key '#{key}' in #{@path}" unless seen_keys.add?(key)
      check_section!(row['section'], i)
      check_section!(row['api_section'], i, field: 'api_section')

      {
        country_code: country_code,
        scheme:       scheme,
        tax_year:     tax_year,
        key:          key,
        # What the figure IS: income, expenses, or neither. A structural
        # question about the row, asked in the app's own vocabulary — NOT the
        # form's word for it. The form's word is `label`, and that one is never
        # translated. See check_section!.
        section:      row['section'],
        # Only set where a submission files a figure somewhere other than where
        # it belongs — tax deducted at source, which HMRC puts inside the income
        # object without it being income. Blank means "same as section", the
        # normal case.
        api_section:  row['api_section'],
        # The box's name on the form, in the form's own language. Never
        # translated: a German Vermietung line is not "service charges" in any
        # language, and offering a translation invites someone to hunt the paper
        # form for a box that is not there.
        label:        row['label'],
        # The authority's own identifier for the box: a Kennzahl on the German
        # forms, a box number on the British ones, an OR article and Ziffer for
        # Switzerland. What you quote to look the figure up — not a name, and
        # not the field a submission uses, which is api_field.
        export_column: row['export_column'],
        # The authority's own field name for this category, used when building a
        # submission payload. Blank for categories with no box of their own,
        # such as tax_taken_off, which is reported at final declaration instead.
        api_field:    row['api_field'],
        position:     row['position'].to_i,
        notes:        row['notes'],
        # Words that mean this box, in the FORM'S own language — never the
        # user's. Matching a translated word against an account name written in
        # the form's language would find nothing anyway. Normalised here, once,
        # so the matcher never has to.
        keywords:     Array(row['keywords']).map { |w| TaxCategoryGuesser.normalise(w) }.reject(&:empty?)
      }
    end

    TaxCategory.upsert_all(
      rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) },
      unique_by: %i[country_code scheme tax_year key]
    )

    # The file is the catalogue, not an addition to it. Without this, a key
    # removed from the YAML stayed in the database for ever — and a category
    # that no longer exists is worse than one that never did, because accounts
    # go on being tagged with it and TaxCsv drops those figures silently.
    # Deleting the row surfaces the problem instead: the account shows up as
    # untagged and asks to be reassigned.
    #
    # The KEYS, not just how many: an account is tagged by key, so these are
    # what tells us whose books just lost a category
    # (TaxCategoryRemovalNotificationJob). Collected before the delete.
    doomed = TaxCategory.where(country_code: country_code, scheme: scheme, tax_year: tax_year)
                        .where.not(key: rows.map { |r| r[:key] })
    removed_keys = doomed.pluck(:key)
    doomed.delete_all
    say_removed(removed_keys.size, scheme, tax_year)

    if removed_keys.any?
      TaxCategoryRemovalNotificationJob.perform_later(
        scheme: scheme, tax_year: tax_year, removed_keys: removed_keys
      )
    end

    rows.size
  end

  private

  # `section` is a FIXED vocabulary of three, and this is the only thing that
  # enforces it — TaxCategory validates it too, but the loader writes through
  # upsert_all, which skips validations, so that validation never runs on the
  # rows that matter.
  #
  # Three values, because there are three answers: it adds, it subtracts, or it
  # is on the form and does neither (tax deducted at source is the live case).
  # The form's own word for the box lives in `label`, untranslated, which is
  # where a reader looks for it anyway.
  #
  # When this was free text the German files said `einnahmen` and
  # `werbungskosten`, Reports::TaxCsv carried a list of the words it happened to
  # know, and a country writing `venituri` got every row, every subtotal and a
  # NET line of zero — silently, and in the submission archive as well as the
  # CSV.
  def check_section!(value, index, field: 'section')
    return if value.blank?
    return if TaxCategory::VALID_SECTIONS.include?(value.to_s)

    raise "Category #{index} has #{field}: #{value.inspect} in #{@path}. " \
          "Must be one of #{TaxCategory::VALID_SECTIONS.join(', ')} — " \
          "this is the app's own vocabulary, not the form's. " \
          "The form's wording for the box belongs in `label`."
  end

  def say_removed(count, scheme, tax_year)
    return if count.zero?
    Rails.logger.info("TaxCategoryLoader: removed #{count} stale category row(s) " \
                      "from #{scheme} #{tax_year} — no longer in #{File.basename(@path)}")
  end
end