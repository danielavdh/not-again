# frozen_string_literal: true
require "test_helper"
require "csv"

module Reports
  class TrialBalanceCsvTest < ActiveSupport::TestCase
    def build_account(code: "110001", name: "Bank GBP")
      accounts(:bank_gbp)
    end

    def build_data(account, currencies: ["GBP"])
      {
        # The controller always supplies this now; a file names what actually
        # answered, and names nothing when nothing did.
        rate_sources: [ExchangeRate.source_for("GBP")],
        accounts: [account],
        currencies_with_data: currencies,
        balances_by_currency: {
          account.id => { "GBP" => { debit: 100, credit: 0 } }
        },
        account_translated: {
          account.id => { debit: 100, credit: 0 }
        },
        totals: {
          debit_by_currency: { "GBP" => 100 },
          credit_by_currency: { "GBP" => 0 },
          translated_debit: 100,
          translated_credit: 0
        }
      }
    end

    # A missing rate leaves account_translated empty, so the export carried a
    # "Debit (EUR)" column reading 0.00 all the way down — a file that looks
    # complete and is not. A CSV has no flash to explain itself, so the gap is
    # declared in the header block beside the source.
    test "a missing rate drops the converted column and says so" do
      account = build_account
      data = build_data(account, currencies: %w[GBP]).merge(
        account_translated: {},
        rate_unavailable: ExchangeRate::RateUnavailable.new(
          from_currency: "GBP", to_currency: "EUR",
          date: Date.new(2018, 7, 1), source: "ecb"
        )
      )

      csv = TrialBalanceCsv.new(data: data, display_currency: "EUR",
                                end_date: Date.new(2018, 9, 30)).generate
      rows = CSV.parse(csv)

      note = rows.find { |r| r.first == "Exchange Rate" }
      assert note, "the export must declare that a rate was missing"
      assert_match(/UNAVAILABLE/, note[1])
      assert_match(/GBP/, note[1])
      assert_match(/ECB/, note[1])

      header = rows.find { |r| r.include?(I18n.t("jargon.account")) }
      assert_not header.any? { |c| c.to_s.include?("(EUR)") },
                 "the converted column must be gone, not zeroed"
      assert header.any? { |c| c.to_s.include?("(GBP)") },
             "the per-currency columns are still correct and must remain"
    end

    test "generates metadata rows" do
      account = build_account
      csv = TrialBalanceCsv.new(
        data: build_data(account),
        display_currency: "GBP",
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      assert_equal "Trial Balance", rows[0][1]
      assert_equal "2026-03-31", rows[1][1]
      assert_equal "GBP", rows[2][1]
      assert_equal "hmrc", rows[3][1]
    end

    test "generates column headers with debit/credit per currency" do
      account = build_account
      csv = TrialBalanceCsv.new(
        data: build_data(account),
        display_currency: "GBP",
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      header = rows[5]
      assert_equal I18n.t("attrs.code"), header[0]
      assert_equal I18n.t("jargon.account"), header[1]
      assert_includes header, "Debit (GBP)"
      assert_includes header, "Credit (GBP)"
    end

    test "includes account row with formatted amounts" do
      account = build_account
      csv = TrialBalanceCsv.new(
        data: build_data(account),
        display_currency: "GBP",
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      account_row = rows.find { |r| r[0] == account.code }
      assert account_row, "expected account row"
      assert_equal "1.00", account_row[2]
    end

    test "includes TOTALS row" do
      account = build_account
      csv = TrialBalanceCsv.new(
        data: build_data(account),
        display_currency: "GBP",
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      total_row = rows.find { |r| r[1] == I18n.t("reports.csv.totals") }
      assert total_row, "expected TOTALS row"
      assert_equal "1.00", total_row[2]
    end

    test "skips accounts with no balance data" do
      account = build_account
      data = build_data(account)
      data[:balances_by_currency] = {}
      csv = TrialBalanceCsv.new(
        data: data,
        display_currency: "GBP",
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      assert_nil rows.find { |r| r[0] == account.code }
    end

    test "includes FX variance rows when non-zero" do
      account = build_account
      csv = TrialBalanceCsv.new(
        data: build_data(account),
        display_currency: "GBP",
        end_date: Date.new(2026, 3, 31),
        fx_variance: 5
      ).generate
      rows = CSV.parse(csv)
      assert rows.any? { |r| r[1] == I18n.t("reports.fx_translation_variance") }
      assert rows.any? { |r| r[1] == I18n.t("reports.adjusted_totals") }
    end

    # See the note in profit_loss_csv_test: printed, not derived.
    test "prints the source it is given, not one derived from the currency" do
      account = build_account
      csv = TrialBalanceCsv.new(
        data: build_data(account).merge(rate_sources: ["ecb"]),
        display_currency: "EUR",
        end_date: Date.new(2026, 3, 31)
      ).generate
      rows = CSV.parse(csv)
      assert_equal "ecb", rows[3][1]
    end
  end
end
