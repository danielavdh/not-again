# frozen_string_literal: true

class TaxCategoryLoader
  # Two catalogues in one file: the boxes, and a VAT scheme's codes.
  Result = Struct.new(:categories, :codes, keyword_init: true)

  REQUIRED_HEADER_KEYS = %w[country_code scheme tax_year].freeze
  REQUIRED_ROW_KEYS    = %w[key].freeze
  ALLOWED_ROW_KEYS     = %w[key section api_section label export_column api_field position notes
                            keywords includes subtracts].freeze
  REQUIRED_CODE_KEYS   = %w[key rate_bps direction valid_from].freeze
  ALLOWED_CODE_KEYS    = %w[key label rate_bps direction valid_from valid_to reverse_charge
                            flat_rate
                            net_category_key tax_category_key reverse_tax_category_key
                            datev_bu position].freeze

  def self.call(path) = new(path).call

  def initialize(path)
    @path = path
  end

  # One transaction: the categories, the codes and the prune are one catalogue,
  # and a file refused halfway through used to leave the boxes updated, the
  # removal email queued, and the doomed code still there.
  def call
    TaxCategory.transaction { load }
  end

  private

  def load
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
        # Boxes of the same form this one totals up — a fact about the form, so
        # a code feeding box 8 reaches box 6 without naming both.
        includes:     Array(row['includes']).map(&:to_s),
        # And boxes it takes AWAY — box 5 of a UK return is box 3 minus box 4.
        subtracts:    Array(row['subtracts']).map(&:to_s),
        notes:        row['notes'],
        # Words that mean this box, in the FORM'S own language — never the
        # user's. Matching a translated word against an account name written in
        # the form's language would find nothing anyway. Normalised here, once,
        # so the matcher never has to.
        keywords:     Array(row['keywords']).map { |w| TaxCategoryGuesser.normalise(w) }.reject(&:empty?)
      }
    end

    # A box totalling boxes that do not exist would just report less than it
    # should, silently.
    declared = rows.map { |r| r[:key] }
    rows.each do |row|
      unknown = (row[:includes] + row[:subtracts]) - declared
      next if unknown.empty?
      raise "Category #{row[:key]} says it includes or subtracts #{unknown.inspect}, which is " \
            "not a category in #{@path}. A box can only total boxes of its own form."
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

    Result.new(
      categories: rows.size,
      codes:      load_tax_codes(data, country_code, scheme, rows.map { |r| r[:key] })
    )
  end

  # Versioned by DATE, so these rows do NOT belong to the file's tax_year the
  # way the categories do — one key may have two rows a decade apart. Hence one
  # file per scheme (TaxSchemeConfig enforces it), pruned against the scheme.
  def load_tax_codes(data, country_code, scheme, category_keys)
    codes = data['tax_codes']
    return 0 if codes.nil?
    raise "'tax_codes:' must be an array in #{@path}" unless codes.is_a?(Array)

    seen = Set.new
    rows = codes.each_with_index.map do |row, i|
      raise "Tax code #{i} must be a Hash in #{@path}" unless row.is_a?(Hash)
      unknown = row.keys - ALLOWED_CODE_KEYS
      raise "Tax code #{i} has unknown keys: #{unknown.inspect} in #{@path}" if unknown.any?
      REQUIRED_CODE_KEYS.each do |k|
        raise "Tax code #{i} missing '#{k}' in #{@path}" if row[k].to_s.empty?
      end
      check_direction!(row['direction'], i)
      check_flat_rate!(row['flat_rate'], i)

      key = row['key'].to_s
      # A rate change is a second row; a second row with the same start date is
      # a copy-paste mistake.
      raise "Duplicate tax code '#{key}' from #{row['valid_from']} in #{@path}" \
        unless seen.add?([ key, row['valid_from'].to_s ])

      # A box key that does not exist would fail nowhere: the figure would never
      # reach the return, for every user of the scheme, silently.
      %w[net_category_key tax_category_key reverse_tax_category_key].each do |field|
        box = row[field]
        next if box.blank? || category_keys.include?(box.to_s)
        raise "Tax code #{key} names #{field}: #{box.inspect}, which is not a category " \
              "in #{@path}. The boxes a code feeds must be boxes of its own scheme."
      end

      {
        country_code:     country_code,
        scheme:           scheme,
        key:              key,
        label:            row['label'],
        # Basis points: 1900 is 19%.
        rate_bps:         row['rate_bps'].to_i,
        # Which control account the leg goes to, and which side.
        direction:        row['direction'].to_s,
        valid_from:       row['valid_from'],
        valid_to:         row['valid_to'],
        # Owed and reclaimed in one breath; posts no leg, reports in two boxes.
        reverse_charge:   row['reverse_charge'] ? true : false,
        # What the flat rate does with it — TaxCode::FLAT_RATE_TREATMENTS. Nil
        # is inside the scheme, which almost every code is.
        flat_rate:        row['flat_rate']&.to_s,
        # Two fields because a rate cannot say which box: a zero-rated supply
        # and an export are both 0% and belong on different lines.
        net_category_key: row['net_category_key'],
        tax_category_key: row['tax_category_key'],
        # The box for the OTHER leg of a reverse charge.
        reverse_tax_category_key: row['reverse_tax_category_key'],
        # What a DATEV import expects.
        datev_bu:         row['datev_bu'],
        position:         row['position'].to_i
      }
    end

    check_no_overlap!(rows)

    TaxCode.upsert_all(
      rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) },
      unique_by: %i[country_code scheme key valid_from]
    )

    prune_tax_codes(scheme, rows)
    rows.size
  end

  # A code with postings is HISTORY: deleting it would orphan the VAT on entries
  # already filed. Retiring a rate means giving it a valid_to.
  def prune_tax_codes(scheme, rows)
    live   = rows.map { |r| [ r[:key], r[:valid_from].to_s ] }
    doomed = TaxCode.where(scheme: scheme).reject { |c|
      live.include?([ c.key, c.valid_from.to_s ])
    }
    return if doomed.empty?

    in_use = TaxCode.where(id: doomed.map(&:id)).joins(:postings).distinct.pluck(:key)
    if in_use.any?
      raise "#{@path} no longer declares tax code(s) #{in_use.sort.join(', ')}, but postings " \
            "use them. A code with postings is history — give it a valid_to instead of " \
            "removing it."
    end

    # An account's remembered default is a form prefill, not history, and the
    # foreign key would otherwise refuse the delete halfway through.
    Account.where(default_tax_code_id: doomed.map(&:id)).update_all(default_tax_code_id: nil)
    TaxCode.where(id: doomed.map(&:id)).delete_all
    Rails.logger.info("TaxCategoryLoader: removed #{doomed.size} unused tax code row(s) " \
                      "from #{scheme} — no longer in #{File.basename(@path)}")
  end

  def check_direction!(value, index)
    return if TaxCode::DIRECTIONS.include?(value.to_s)

    raise "Tax code #{index} has direction: #{value.inspect} in #{@path}. " \
          "Must be one of #{TaxCode::DIRECTIONS.join(', ')} — input is VAT we paid and " \
          "reclaim, output is VAT we charged and owe."
  end

  def check_flat_rate!(value, i)
    return if value.nil? || TaxCode::FLAT_RATE_TREATMENTS.include?(value.to_s)
    raise "Tax code #{i} has flat_rate: #{value.inspect} in #{@path}; " \
          "one of #{TaxCode::FLAT_RATE_TREATMENTS.join(', ')}, or leave it out"
  end

  # Two rows of one key in force on the same day would resolve by id — the
  # older rate, silently. A rate change is a valid_to on the old row and a
  # valid_from on the new, and the two must not overlap.
  def check_no_overlap!(rows)
    rows.group_by { |r| r[:key] }.each do |key, versions|
      versions.sort_by { |r| r[:valid_from].to_s }.each_cons(2) do |earlier, later|
        next if earlier[:valid_to].present? && earlier[:valid_to].to_s < later[:valid_from].to_s
        raise "Tax code #{key} from #{earlier[:valid_from]} is still in force when the row " \
              "from #{later[:valid_from]} begins, in #{@path}. Give the earlier row a valid_to " \
              "before the later row's valid_from."
      end
    end
  end

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