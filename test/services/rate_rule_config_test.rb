# frozen_string_literal: true
require "test_helper"

# Tier 2: which rate a country's tax law accepts for a figure that is SUBMITTED.
#
# The line this file defends is the one between tier 1 and tier 2. Tier 1 knows
# what a source IS and names no country; this knows what a country ACCEPTS and
# describes no feed. An ordinary report asks the first and must keep asking it —
# a euro profit and loss reads the ECB even in Germany, because §16(6) UStG
# governs a VAT RETURN, not a screen.
class RateRuleConfigTest < ActiveSupport::TestCase
  test "a country's accepted sources are ordered, most preferred first" do
    assert_equal %w[hmrc], RateRuleConfig.accepted_sources("gb")
    # Germany's VAT override is the live ordered list: the Bundesbank average
    # §16(6) UStG names, then the ECB where it does not reach.
    assert_equal %w[bundesbank ecb],
                 RateRuleConfig.accepted_sources("de", scheme: "umsatzsteuer")
  end

  # Within one country, VAT and income tax do not want the same series. That is
  # the whole reason for a per-scheme override.
  test "a scheme overrides its country's list" do
    assert_equal %w[ecb], RateRuleConfig.accepted_sources("de")
    assert_equal %w[ecb], RateRuleConfig.accepted_sources("de", scheme: "de_euer")
    assert_equal %w[bundesbank ecb],
                 RateRuleConfig.accepted_sources("de", scheme: "umsatzsteuer")
  end

  test "an override replaces only the field it names" do
    assert_equal "transaction_date",
                 RateRuleConfig.date_basis_for("de", scheme: "umsatzsteuer"),
                 "date_basis is not overridden, so it must be inherited"
    assert_equal "manual_with_evidence",
                 RateRuleConfig.unpublished_currency_for("de", scheme: "umsatzsteuer")
  end

  # Empty, not an exception and not a default. A country with no rule falls back
  # to tier 1, which is the correct answer for every country whose tax
  # vocabulary nobody has written yet.
  test "a country with no rule accepts nothing, so tier 1 decides" do
    assert_equal [], RateRuleConfig.accepted_sources("bg")
    assert_not RateRuleConfig.exists?("bg")
    assert_nil RateRuleConfig.preferred_source("bg")
  end

  test "case and symbols do not matter" do
    assert_equal %w[hmrc], RateRuleConfig.accepted_sources("GB")
    assert_equal %w[hmrc], RateRuleConfig.accepted_sources(:gb)
  end

  # The file describes tax law, not one deployment's feeds. A rule may name a
  # source this installation has not configured.
  test "preferred_source skips a source the app does not carry" do
    RateRuleConfig.stub(:accepted_sources, %w[bank_of_nowhere ecb]) do
      assert_equal "ecb", RateRuleConfig.preferred_source("de")
    end
  end

  # THE GAP THAT NOTHING CLOSED. The rules file and the tax category files are
  # two halves of tier 2, and checking only RateRuleConfig.all — the countries
  # that already HAVE a rule — means a country can arrive with tax category
  # files and no rule and no test notices.
  #
  # What happens then is the worst available outcome: accepted_sources returns
  # [], ExchangeRate.sources_for_scheme takes .presence and gets nil, and the
  # submission converts at TIER 1's base-matching — the rule for a report you
  # look at, not for a figure you file. No error, no warning, a filed number
  # converted at a rate the authority never named.
  test "every country with tax category files declares its accepted rate sources" do
    TaxSchemeConfig.countries.each do |country|
      assert RateRuleConfig.exists?(country),
             "#{country} has tax category files but no entry in db/exchange_rate_rules.yml. " \
             "Without one, a SUBMISSION silently falls back to tier 1's base-matching."
      assert RateRuleConfig.accepted_sources(country).any?,
             "#{country} has an empty accepts: list, which reads as 'no rule' rather than 'accept nothing'"
    end
  end

  # The other direction. A rule for a country with no tax category files can
  # never fire — `scheme:` is what reaches this file, and a scheme comes from a
  # tax category file. Dead config that reads as though it were doing something.
  test "every country in the rules has tax category files" do
    RateRuleConfig.all.each do |country|
      assert_includes TaxSchemeConfig.countries, country,
                      "#{country} has a rate rule but no tax category files, so the rule can never fire"
    end
  end

  # `date_basis` does something, so a value the Translator does not recognise is
  # no longer harmless prose: it reads as a declared rule and behaves as the
  # default. Same disease as free-text `section`, same cure.
  test "every declared date_basis is one the translator understands" do
    RateRuleConfig.all.each do |country|
      rule   = RateRuleConfig.config[country]
      values = [ rule["date_basis"] ] + (rule["schemes"] || {}).values.map { |o| o["date_basis"] }

      values.compact.each do |value|
        assert_includes RateRuleConfig::DATE_BASES, value,
                        "#{country} declares date_basis: #{value.inspect}, which nothing implements"
      end
    end
  end

  # Every source named anywhere in the rules must exist in tier 1, or the rule
  # silently does nothing.
  test "every declared source exists in the source registry" do
    RateRuleConfig.all.each do |country|
      rule = RateRuleConfig.config[country]
      lists = [ rule["accepts"] ] + (rule["schemes"] || {}).values.map { |o| o["accepts"] }

      lists.compact.flatten.each do |source|
        assert RateSourceConfig.exists?(source),
               "#{country} accepts #{source}, which is not in exchange_rate_sources.yml"
      end
    end
  end

  # A list may legitimately name only a source that cannot reach the past. The
  # app answers a period it cannot serve with a warning and a link to enter the
  # rate by hand — which is the compliant route anyway, since the authority
  # publishes its own history where a business can look it up.
  #
  # Requiring every `accepts:` list to END with a backfillable source looks
  # reasonable and is not: the fix it enforced was putting `ecb` in
  # Switzerland's accepts list, and Art. 45 MWSTV does not permit the ECB rate.
  # That is an engineering fallback written into a field that states tax law.
  test "a country accepts only what its authority actually permits" do
    assert_equal %w[estv], RateRuleConfig.accepted_sources("ch"),
                 "Art. 45 MWSTV permits the ESTV rate, a daily selling rate, or a group rate. " \
                 "The ECB reference rate is none of those and must not be listed here."
  end

  # The guarantee that makes the above safe: a submission bound to a source that
  # cannot reach a period gets an ERROR, never a figure from somewhere else.
  test "a period no accepted source covers produces no rate at all" do
    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "CHF", source: "ecb", rate: 0.97,
      effective_date: Date.new(2026, 3, 1),
      valid_from: Date.new(2026, 3, 1), valid_to: Date.new(2026, 3, 31)
    )

    translator = ExchangeRate.translator("CHF", date: Date.new(2026, 3, 15),
                                              scheme: "ch_selbst")
    assert_raises(ExchangeRate::RateUnavailable) do
      translator.rate("EUR", on: Date.new(2026, 3, 15))
    end
  end

  # …and an ordinary report is NOT bound. This file governs submissions only.
  # Without a scheme, tier 1 answers and still reads the ECB, so removing it
  # from Switzerland's accepts list cost no report anything.
  test "a report with no scheme still converts through tier 1" do
    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "CHF", source: "ecb", rate: 0.97,
      effective_date: Date.new(2026, 3, 1),
      valid_from: Date.new(2026, 3, 1), valid_to: Date.new(2026, 3, 31)
    )

    # Tier 1 prefers ESTV for francs, and there is none for March — so a REPORT
    # cross-rates for its whole period. That decision is source_for_span's, made
    # before any translator exists, and this is the source it hands over.
    source = ExchangeRate.source_for_span("CHF", from_currencies: [ "EUR" ],
                                          from: Date.new(2026, 3, 1), to: Date.new(2026, 3, 31))
    assert_equal "ecb", source, "no ESTV for the period, so the report cross-rates"

    translator = ExchangeRate.translator("CHF", date: Date.new(2026, 3, 15), sources: [ source ])
    assert_equal 0.97, translator.rate("EUR", on: Date.new(2026, 3, 15))
  end

end
