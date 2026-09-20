# frozen_string_literal: true

module Reports
  # Whether a report's final, translating column earns its place. Every report
  # ends with a column converting all currencies into one, and it says something
  # useful only when there is something to convert: with a single currency that
  # already IS the target, it merely repeats the column beside it.
  #
  # One home for the rule because five things must agree about it — the four
  # report views and the CSV exporters, which render the same table.
  module CurrencyColumns
    # forced: — the target currency is imposed rather than incidental, i.e. a
    # tax report whose scheme declares what it files in. Without that, a single-
    # currency report has no reason to translate: the target would only be a
    # session default nobody chose, and the result a figure in nobody's books.
    def self.translated?(currencies, display_currency, forced: false)
      currencies = Array(currencies)
      return true if currencies.empty?
      return true if currencies.size > 1
      forced && currencies.first != display_currency
    end

    # The target is the user's to choose only when there is a real choice: two
    # or more currencies to reconcile. Never on a tax report — the scheme
    # declares the currency, so it is not theirs to change.
    def self.selectable?(currencies, tax_report: false)
      !tax_report && Array(currencies).size > 1
    end

    # Whether to name the series that produced the converted column. It earns
    # its place only when it says something the dropdown cannot:
    #
    # · no dropdown at all — a tax report, whose currency is the scheme's and
    # whose source is its country's law
    # · MORE THAN ONE source answered, meaning a fallback fired: ESTV reaches
    # back one month and the ECB covers the rest, so a single column can
    # legitimately mix them
    #
    # That second case is the one that matters. A conversion is defensible only
    # if you can say which published rate produced it, and no dropdown can
    # express "these months came from somewhere else".
    def self.name_source?(sources, selectable:)
      sources = Array(sources)
      return false if sources.empty?

      !selectable || sources.size > 1
    end
  end
end
