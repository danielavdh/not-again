# frozen_string_literal: true

module Reports
  # A saved TAX report: the scheme's tagged accounts, grouped by tax CATEGORY
  # rather than by parent account, banded into income / expenses / other with a
  # net line. The shared pipeline is in Reports::Presenter; this supplies the
  # account set, the rate policy (the scheme's accepted series) and the category
  # grouping.
  #
  # Same source as the filing: these category totals are the same LedgerBalances
  # + Translation the submission is built from (Reports::TaxCategoryTotals), so
  # the report a bookkeeper reads and the figure filed can never disagree.
  SECTION_ORDER = { TaxCategory::INCOME => 0, TaxCategory::EXPENSES => 1, TaxCategory::OTHER => 2 }.freeze

  class TaxReport < Presenter
    private

    def group
      @group ||= report.report_group
    end

    # The scheme's tagged accounts, in the catalogue's order. Same set the
    # filing reads.
    def ordered_accounts
      @ordered_accounts ||= report.accounts.to_a
    end

    # A tax report reads its country's accepted series and date basis, never
    # tier 1 and never a reader's dropdown choice — the scheme declares both.
    def translation
      @translation ||= Reports::Translation.new(
        display_currency: display_currency,
        scheme:           group.tax_scheme,
        entity_id_for:    ->(_) { group.entity&.id }
      )
    end

    def empty_result
      { report: report, display_currency: display_currency, currencies: [], category_groups: [] }
    end

    def build(accounts)
      cats = load_categories(accounts)

      groups = group_by_category(accounts, cats)
      annotate_section_boundaries(groups)
      section_totals = build_section_totals(groups)

      {
        report:           report,
        display_currency: display_currency,
        currencies:       @currencies,
        category_groups:  groups,
        section_totals:   section_totals,
        net:              net_line(section_totals),
        last_section:     groups.last&.fetch(:section, nil),
        rate_unavailable: rate_unavailable,
        rate_sources:     rate_sources_used
      }
    end

    # The catalogue as it stood for the period being reported — same lookup
    # Reports::TaxCategoryTotals uses.
    def load_categories(accounts)
      keys = accounts.filter_map { |a| a.tax_category_key.presence }.uniq
      TaxCategory.for_period(
        scheme: group.tax_scheme,
        keys:   keys,
        year:   TaxCategory.tax_year_for(
                  country_code: TaxSchemeConfig.country_for(group.tax_scheme),
                  date:         report.end_date
                )
      )
    end

    # [ { key:, label:, reference:, section:, accounts: [row,...],
    # currency_totals:, translated_total: } ], ordered by section then the
    # catalogue's own position.
    #
    # An account whose category is not in the catalogue for this period — a
    # retired box — lands in a trailing group with section nil: shown so the
    # bookkeeper sees it, never folded into a total.
    def group_by_category(accounts, cats)
      by_key = Hash.new { |h, k| h[k] = [] }
      accounts.each do |account|
        row = account_row(account)
        next unless row
        # An inactive account only reaches a tax report because it has activity
        # in the period — flag it so the bookkeeper sees why it is there.
        row[:inactive] = !account.active?
        by_key[account.tax_category_key.presence] << row
      end

      groups = by_key.map do |key, rows|
        cat = key && cats[key]
        currency_totals = Hash.new(0)
        translated_total = 0
        rows.each do |r|
          r[:currency_totals].each { |c, a| currency_totals[c] += a }
          translated_total += r[:translated_total]
        end

        {
          key:              key,
          label:            cat&.label || I18n.t("reports.show.tax_uncategorised"),
          reference:        cat&.reference,
          section:          cat&.section,
          accounts:         rows,
          currency_totals:  currency_totals,
          translated_total: translated_total
        }
      end

      groups.sort_by do |g|
        [ SECTION_ORDER.fetch(g[:section], 9), catalogue_position(cats, g[:key]), g[:key].to_s ]
      end
    end

    def catalogue_position(cats, key)
      cats[key]&.position || 9_999
    end

    # Which category opens a new section, so the template can print that
    # section's running total before it and a heading for the new one. Mirrors
    # CustomReport#annotate_type_boundaries.
    def annotate_section_boundaries(groups)
      last = :none
      groups.each do |g|
        next if g[:section] == last
        g[:preceding_section_total] = (last == :none ? nil : last)
        g[:section_header]          = g[:section]
        last = g[:section]
      end
      groups
    end

    def build_section_totals(groups)
      totals = Hash.new { |h, k| h[k] = { currency_totals: Hash.new(0), translated_total: 0 } }
      groups.each do |g|
        next if g[:section].blank?
        g[:currency_totals].each { |c, a| totals[g[:section]][:currency_totals][c] += a }
        totals[g[:section]][:translated_total] += g[:translated_total]
      end
      totals
    end

    # Income − expenses, per currency and translated. "Other" is reported, not
    # netted (it is tax already paid, not a trading figure).
    def net_line(section_totals)
      inc = section_totals[TaxCategory::INCOME]
      exp = section_totals[TaxCategory::EXPENSES]
      currency_totals = Hash.new(0)
      (inc[:currency_totals].keys | exp[:currency_totals].keys).each do |c|
        currency_totals[c] = inc[:currency_totals][c].to_i - exp[:currency_totals][c].to_i
      end
      { currency_totals: currency_totals,
        translated_total: inc[:translated_total] - exp[:translated_total] }
    end
  end
end
