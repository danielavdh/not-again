# frozen_string_literal: true
require "test_helper"
require "csv"
require "ostruct"

module Reports
  class StandardCsvTest < ActiveSupport::TestCase
    def build_data(currencies: ["GBP"], account_type: "income", parent_groups: nil)
      account_data = {
        id: 1,
        code: "410001",
        name: "Sales",
        account_type: account_type,
        entries: [
          { date: Date.new(2026, 1, 15), description: "Invoice", currency: "GBP",
            amount: 100, translated_amount: 100 }
        ],
        currency_totals: { "GBP" => 100 },
        translated_total: 100
      }
      {
        currencies: currencies,
        show_type_totals: false,
        type_totals: {},
        parent_groups: parent_groups || [{
          parent_id: 1,
          parent_code: "4100",
          parent_name: "Sales Group",
          accounts: [account_data],
          currency_totals: { "GBP" => 100 },
          translated_total: 100
        }]
      }
    end

    def fake_report
      OpenStruct.new(name: "Q1 2026", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 3, 31),
                     report_group: OpenStruct.new(display_name: "Laura Music"))
    end

    # The file opens with provenance rows now, so the header is found rather
    # than assumed to be first.
    def header_of(rows)
      rows.find { |r| r.first == I18n.t("attrs.code") }
    end

    # --- Short version ---

    # The saved-report export is a FOURTH exporter and was missed when the other
    # three were fixed — a real download came back with the EUR column reading
    # 0.00 on every row. rate_unavailable arrives in the same data hash
    # CustomReport already builds; it just was not being read.
    test "a missing rate drops the display-currency column and says so" do
      # `report` is stored and never read by #generate, so nil is honest here
      # and avoids inventing a fixture for something the exporter ignores.
      gap = ExchangeRate::RateUnavailable.new(
        from_currency: "GBP", to_currency: "EUR",
        date: Date.new(2018, 7, 1), source: "ecb"
      )

      csv = StandardCsv.new(
        report: nil,
        data: { currencies: %w[GBP], parent_groups: [], type_totals: {},
                show_type_totals: false, rate_unavailable: gap },
        display_currency: "EUR",
        short_version: true
      ).generate
      rows = CSV.parse(csv)

      note = rows.find { |r| r.first == "Exchange Rate" }
      assert note, "the export must declare that a rate was missing"
      assert_match(/UNAVAILABLE/, note[1])
      assert_match(/ECB/, note[1])

      header = rows.find { |r| r.include?(I18n.t("jargon.account")) }
      assert_not_includes header, "EUR", "the display-currency column must be gone, not zeroed"
      assert_includes header, "GBP", "the per-currency column is still correct"
    end

    test "short version generates header with currencies then display currency" do
      csv = StandardCsv.new(
        report: fake_report,
        data: build_data(currencies: ["GBP", "EUR"]),
        display_currency: "GBP",
        short_version: true
      ).generate
      rows = CSV.parse(csv)
      assert_equal [ I18n.t("attrs.code"), I18n.t("jargon.account"), "GBP", "EUR",
                     I18n.t("reports.csv.total_of", name: "GBP") ], header_of(rows)
    end

    test "short version emits one row per account" do
      csv = StandardCsv.new(
        report: fake_report,
        data: build_data,
        display_currency: "GBP",
        short_version: true
      ).generate
      rows = CSV.parse(csv)
      account_rows = rows.select { |r| r[0] == "410001" }
      assert_equal 1, account_rows.size
      assert_equal "Sales", account_rows.first[1]
      assert_equal "1.00", account_rows.first[2]
    end

    test "short version skips zero-balance accounts" do
      data = build_data
      data[:parent_groups].first[:accounts].first[:currency_totals] = {}
      data[:parent_groups].first[:accounts].first[:translated_total] = 0
      csv = StandardCsv.new(
        report: fake_report,
        data: data,
        display_currency: "GBP",
        short_version: true
      ).generate
      rows = CSV.parse(csv)
      account_rows = rows.select { |r| r[0] == "410001" }
      assert_equal 0, account_rows.size
    end

    test "short version emits parent total row when multiple accounts" do
      data = build_data
      second = data[:parent_groups].first[:accounts].first.dup
      second[:id] = 2
      second[:code] = "410002"
      second[:name] = "Other Sales"
      data[:parent_groups].first[:accounts] << second
      csv = StandardCsv.new(
        report: fake_report,
        data: data,
        display_currency: "GBP",
        short_version: true
      ).generate
      rows = CSV.parse(csv)
      total_rows = rows.select { |r| r[1]&.include?("Total") }
      assert total_rows.any?, "expected a parent total row"
    end

    # Excel and Numbers style ROW 1 as the header row, which here is provenance,
    # not the real header. So the total column is named there as well, or the
    # sticky header sits over a column of figures saying nothing.
    test "row 1 names the total column, because a spreadsheet treats it as the header" do
      csv = StandardCsv.new(
        report: fake_report,
        data: build_data(currencies: ["GBP", "EUR"]),
        display_currency: "GBP",
        short_version: true
      ).generate
      rows = CSV.parse(csv)

      assert_equal header_of(rows).size, rows.first.size,
                   "row 1 must be as wide as the table for the label to land on the right column"
      assert_equal I18n.t("reports.csv.total_of", name: "GBP").upcase, rows.first.last
    end

    # Single currency: no total column, so nothing to name.
    test "row 1 is left alone when there is no total column" do
      csv = StandardCsv.new(
        report: fake_report,
        data: build_data,
        display_currency: "GBP",
        short_version: true
      ).generate
      assert_equal [ I18n.t("reports.csv.report"), "Laura Music" ], CSV.parse(csv).first
    end

    # --- Long version ---

    # The translating column is dropped when it would only repeat the column
    # beside it. This used to assert ["…", "GBP", "GBP"] — the duplication
    # itself, encoded as expected behaviour.
    test "long version omits the translating column for a single currency" do
      csv = StandardCsv.new(
        report: fake_report,
        data: build_data,
        display_currency: "GBP",
        short_version: false
      ).generate
      rows = CSV.parse(csv)
      assert_equal [ I18n.t("attrs.code"), I18n.t("attrs.date"), I18n.t("jargon.account"), "GBP" ], header_of(rows)
    end

    test "the translating column stays when it translates something" do
      # GBP books, totalled in EUR: the last column is the only place the
      # translated figure appears.
      csv = StandardCsv.new(
        report: fake_report,
        data: build_data,
        display_currency: "EUR",
        short_version: false
      ).generate
      assert_equal [ I18n.t("attrs.code"), I18n.t("attrs.date"), I18n.t("jargon.account"), "GBP",
                     I18n.t("reports.csv.total_of", name: "EUR") ], header_of(CSV.parse(csv))
    end

    test "long version emits an entry row per transaction" do
      csv = StandardCsv.new(
        report: fake_report,
        data: build_data,
        display_currency: "GBP",
        short_version: false
      ).generate
      rows = CSV.parse(csv)
      entry_rows = rows.select { |r| r[1] == "2026-01-15" }
      assert_equal 1, entry_rows.size
      assert_equal "Invoice", entry_rows.first[2]
    end

    # --- Empty data ---

    test "empty parent_groups returns only header row" do
      data = build_data(parent_groups: [])
      csv = StandardCsv.new(
        report: fake_report,
        data: data,
        display_currency: "GBP",
        short_version: true
      ).generate
      rows = CSV.parse(csv)
      assert_equal header_of(rows), rows.last,
                   "with no figures, the header is the last row in the file"
    end
  end
end
