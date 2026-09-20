# frozen_string_literal: true

module ReportsHelper
  # Thin wrappers over Reports::CurrencyColumns, which holds the rule the views
  # and the CSV exporters must agree on.
  #
  # A MISSING RATE DOES NOT REMOVE THE COLUMN ON SCREEN. The column header is
  # where the currency-and-source SELECT lives, so dropping it takes away the
  # only control that could get you out: pick a series with no rate for the
  # period and the page comes back with no way back except editing the URL by
  # hand.
  #
  # It is safe to keep, because the cells empty themselves — every call site
  # defaults a missing translation to 0, and format_cents_with_currency renders
  # 0 as "" unless asked for show_zero. So the column shows headers, the select,
  # and blank cells, while _rate_unavailable says why above the table.
  #
  # The CSV exporters still DROP it, and should: a file has no flash and
  # outlives the person who downloaded it, so an empty column there would read
  # as "these figures are zero".
  #
  # Read from the view context rather than threaded through 29 call sites.
  # report_colspan calls this same method, so the colspans stay in step with the
  # header automatically.
  def translated_column?(currencies, display_currency, forced: false)
    Reports::CurrencyColumns.translated?(currencies, display_currency, forced: forced)
  end

  def currency_selectable?(currencies, tax_report: false)
    Reports::CurrencyColumns.selectable?(currencies, tax_report: tax_report)
  end

  # The converted-column dropdown comes GROUPED when there are both used and
  # unused currencies, and FLAT when one of those groups is empty — an optgroup
  # containing everything is a heading that divides nothing. Choosing between
  # the two Rails helpers is the only thing a template would otherwise have to
  # know about that.
  def currency_select_options(options, selected)
    return grouped_options_for_select(options, selected) if options.is_a?(Hash)

    options_for_select(options, selected)
  end

  def name_rate_source?(sources, selectable:)
    Reports::CurrencyColumns.name_source?(sources, selectable: selectable)
  end

  # Columns spanned by a full-width row: the account column, one per currency,
  # and the translating column when it is shown.
  def report_colspan(currencies, display_currency, forced: false)
    1 + Array(currencies).size +
      (translated_column?(currencies, display_currency, forced: forced) ? 1 : 0)
  end

  # The "Exchange Rate Variance" figure on the balance sheet, P&L and trial
  # balance links to the page that itemises the transfers behind it. Same period
  # and scope as the report it sits on — a balance sheet is cumulative, so it
  # passes no start_date.
  def fx_variance_label_link(start_date: nil, end_date:, entities: nil, currency: nil)
    link_to t("reports.fx_translation_variance"),
            fx_variance_reports_path(
              start_date: start_date, end_date: end_date,
              entities: Array(entities).presence&.join(","), currency: currency
            ),
            class: "report-account-link"
  end
end
