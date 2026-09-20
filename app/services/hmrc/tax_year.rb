# frozen_string_literal: true

module Hmrc
  # UK tax-year arithmetic, in one place so the "cumulative from 2025-26"
  # boundary cannot drift between the client, which selects the endpoint, and
  # the filing service, which computes the cumulative date range.
  module TaxYear
    module_function

    # Tax-year label for a date, e.g. Date.new(2026, 7, 1) => "2026-27".
    def label(date)
      if date >= Date.new(date.year, 4, 6)
        "#{date.year}-#{(date.year + 1).to_s[-2..]}"
      else
        "#{date.year - 1}-#{date.year.to_s[-2..]}"
      end
    end

    # First day (6 April) of the tax year containing the date. Used only as a
    # fallback — the real cumulative start is read from HMRC's obligations.
    def start_date(date)
      if date >= Date.new(date.year, 4, 6)
        Date.new(date.year, 4, 6)
      else
        Date.new(date.year - 1, 4, 6)
      end
    end

    # Quarterly updates are cumulative (year-to-date) from tax year 2025-26 on.
    def cumulative?(date)
      label(date) >= "2025-26"
    end
  end
end
