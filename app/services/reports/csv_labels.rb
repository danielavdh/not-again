# frozen_string_literal: true

module Reports
  # The words in an exported file, in the reader's language.
  #
  # REUSES the screen's keys wherever the screen already has the word. "Code",
  # "Account", "Date", the exchange rate variance and the report names are all
  # on screen already, and a second set would drift from the first. Only what is
  # genuinely export-only lives under acc.reports.csv.
  #
  # A module rather than a base class because the five exporters have nothing
  # else in common and are not a hierarchy.
  module CsvLabels
    private

    # Export-only wording: section banners, the metadata block, totals rows.
    def csv_label(key, **args)
      I18n.t("reports.csv.#{key}", **args)
    end

    # Words the screen already has. Named so a reader can see at a glance that
    # nothing is being duplicated.
    def shared_label(key, **args)
      I18n.t(key, **args)
    end
  end
end
