# frozen_string_literal: true
require "test_helper"

# Countries, schemes and authorities are derived from the YAML headers in
# db/tax_categories — nothing is hardcoded. These lock that derivation,
# including the ordering the tax forms rely on.
class TaxSchemeConfigTest < ActiveSupport::TestCase
  test "countries come from the catalogue headers" do
    assert_equal %w[ch de gb nl], TaxSchemeConfig.countries
  end

  test "schemes are grouped by country and ordered by their position header" do
    assert_equal %w[gb_self_employment gb_property], TaxSchemeConfig.schemes_for("gb")
    assert_equal %w[de_euer de_vermietung],             TaxSchemeConfig.schemes_for("de")
    assert_equal %w[ch_selbst],                      TaxSchemeConfig.schemes_for("ch")
  end

  test "schemes_for is case-insensitive and empty for an unknown country" do
    assert_equal %w[ch_selbst], TaxSchemeConfig.schemes_for("CH")
    assert_equal [], TaxSchemeConfig.schemes_for("xx")
    assert_equal [], TaxSchemeConfig.schemes_for(nil)
  end

  # Switzerland's authority is a deliberate simplification: the self-employed
  # are assessed BY THE CANTON, and no federal form has income and expense
  # boxes, which is why the catalogue's categories come from OR Art. 959b.
  # "ESTV" is used because it is the name a Swiss user recognises and the one
  # the rate feed carries.
  test "authority is read from the header" do
    assert_equal "HMRC",   TaxSchemeConfig.authority("gb")
    assert_equal "ELSTER", TaxSchemeConfig.authority("de")
    assert_equal "ESTV", TaxSchemeConfig.authority("ch")
  end

  test "authority is nil for a country with no catalogue" do
    assert_nil TaxSchemeConfig.authority("xx")
    assert_nil TaxSchemeConfig.authority(nil)
  end

  test "connector is set only where a scheme can be submitted digitally" do
    assert_equal "hmrc_mtd", TaxSchemeConfig.connector_for("gb_self_employment")
    assert_equal "hmrc_mtd", TaxSchemeConfig.connector_for("gb_property")
    # DE and CH stop at account tagging and CSV export — no connector.
    assert_nil TaxSchemeConfig.connector_for("de_euer")
    assert_nil TaxSchemeConfig.connector_for("ch_selbst")
    assert_nil TaxSchemeConfig.connector_for("no_such_scheme")
  end

  test "the model reads its country list and schemes from the catalogue" do
    assert_equal TaxSchemeConfig.countries,          Entity.valid_country_codes
    assert_equal TaxSchemeConfig.schemes_by_country, Entity.schemes_by_country
    # every scheme, from every country — an entity is not confined to one
    assert_equal TaxSchemeConfig.all_schemes,
                 Entity.new.available_tax_schemes
  end

  # The scheme-first lookups below work only because a slug names exactly one
  # country. Reuse a slug in a new catalogue file and an entity filing in two
  # countries resolves the wrong catalogue, authority and connector, silently.
  test "scheme slugs are unique across countries" do
    all = TaxSchemeConfig.schemes_by_country.values.flatten
    duplicates = all.tally.select { |_, n| n > 1 }.keys
    assert_empty duplicates,
      "scheme slugs must be unique across countries; reused: #{duplicates.inspect}"
  end

  test "a scheme names its own country, authority and connector" do
    assert_equal "gb", TaxSchemeConfig.country_for("gb_self_employment")
    assert_equal "de", TaxSchemeConfig.country_for("de_vermietung")
    assert_equal "ch", TaxSchemeConfig.country_for("ch_selbst")

    assert_equal "HMRC",   TaxSchemeConfig.authority_for("gb_property")
    assert_equal "ELSTER", TaxSchemeConfig.authority_for("de_euer")

    assert_equal "hmrc_mtd", TaxSchemeConfig.connector_for("gb_self_employment")
    assert_nil TaxSchemeConfig.connector_for("de_euer")
  end

  test "scheme-first lookups are nil for an unknown scheme" do
    assert_nil TaxSchemeConfig.country_for("no_such_scheme")
    assert_nil TaxSchemeConfig.authority_for("no_such_scheme")
    assert_nil TaxSchemeConfig.connector_for("no_such_scheme")
    assert_nil TaxSchemeConfig.country_for(nil)
  end

  test "all_schemes lists every scheme, country then declared position" do
    assert_equal %w[ch_selbst de_euer de_vermietung gb_self_employment gb_property nl_winst],
                 TaxSchemeConfig.all_schemes
  end

  # The point of the decoupling: an entity carrying schemes from two countries
  # resolves each one's authority and connector independently.
  test "an entity with schemes in two countries resolves each independently" do
    entity = Entity.new(code: "99", name: "Two countries",
                             tax_schemes: %w[gb_self_employment de_vermietung])
    assert entity.valid?, entity.errors.full_messages.to_sentence

    assert_equal "hmrc_mtd", TaxSchemeConfig.connector_for("gb_self_employment")
    assert_equal "HMRC",     TaxSchemeConfig.authority_for("gb_self_employment")
    assert_nil               TaxSchemeConfig.connector_for("de_vermietung")
    assert_equal "ELSTER",   TaxSchemeConfig.authority_for("de_vermietung")
  end

  # Guessing is by account NAME, not by code digit: the same digit means
  # different things in Germany and Britain, so a digit-based guesser had to
  # refuse a two-country entity outright. Each scheme answers about its own
  # accounts.
  test "an entity filing in two countries still gets suggestions" do
    Dir[Rails.root.join("db/tax_categories/*.yml")].sort.each do |path|
      TaxCategoryLoader.call(path)
    end

    assert_equal "professional_fees",
                 TaxCategoryGuesser.for_scheme("gb_self_employment").guess("Accountancy fees")
    assert_equal "erhaltungsaufwand",
                 TaxCategoryGuesser.for_scheme("de_vermietung").guess("Renovierung")
  end

  # Declared, never derived: the capitalisation follows each scheme's own
  # language, so no rule could infer it from the slug.
  test "report_name and currency come from the scheme's header" do
    assert_equal "GB-self-employment", TaxSchemeConfig.report_name("gb_self_employment")
    assert_equal "GB-property",        TaxSchemeConfig.report_name("gb_property")
    assert_equal "DE-EÜR",             TaxSchemeConfig.report_name("de_euer")
    assert_equal "DE-Vermietung",      TaxSchemeConfig.report_name("de_vermietung")
    assert_equal "CH-Selbst",          TaxSchemeConfig.report_name("ch_selbst")

    assert_equal "GBP", TaxSchemeConfig.currency_for("gb_self_employment")
    assert_equal "EUR", TaxSchemeConfig.currency_for("de_euer")
    assert_equal "CHF", TaxSchemeConfig.currency_for("ch_selbst")

    assert_nil TaxSchemeConfig.report_name("no_such_scheme")
    assert_nil TaxSchemeConfig.currency_for("no_such_scheme")
  end

  test "report names are unique, so two tax reports never share a name" do
    names = TaxSchemeConfig.all_schemes.map { |s| TaxSchemeConfig.report_name(s) }
    assert_equal names.uniq, names, "duplicate report_name in the catalogue: #{names.inspect}"
  end

  test "every catalogue file declares the header keys the config depends on" do
    Dir.glob(Rails.root.join("db", "tax_categories", "*.yml")).each do |path|
      header = YAML.safe_load_file(path)
      %w[country_code scheme tax_year authority report_name currency].each do |key|
        assert header[key].present?, "#{File.basename(path)} is missing '#{key}'"
      end
      assert_match(/\A[A-Z]{3}\z/, header["currency"].to_s.upcase,
                   "#{File.basename(path)} currency must be a 3-letter code")
    end
  end

  # A tax form's name does not translate, so it is not a locale key.
  test "a scheme is named by its own file, in its own language" do
    assert_equal "UK Property (SA105)",   TaxSchemeConfig.scheme_label("gb_property")
    assert_equal "EÜR",                    TaxSchemeConfig.scheme_label("de_euer")
    assert_equal "Selbständigerwerbende", TaxSchemeConfig.scheme_label("ch_selbst")
  end

  test "an unknown scheme falls back to its slug rather than raising" do
    assert_equal "Ro pit", TaxSchemeConfig.scheme_label("ro_pit")
  end

  # The fallback is a safety net, not an option: a humanised slug reads as a
  # name ("Gb property") without being one, so a file that forgets the field
  # looks fine and is wrong. Nothing but this would surface it.
  test "every scheme declares its label rather than relying on the fallback" do
    Dir.glob(Rails.root.join("db", "tax_categories", "*.yml")).each do |path|
      header = YAML.safe_load_file(path)
      assert header["scheme_label"].present?,
             "#{File.basename(path)} is missing scheme_label"
      assert_not_equal header["scheme"].to_s.humanize, header["scheme_label"].to_s,
                       "#{File.basename(path)} declares a label identical to the fallback"
    end
  end

  # CurrencyConfig.symbol_for returns "" for a currency it does not know, so a
  # tax report would total into a column with no symbol at all — which is why
  # Filing::Base#submission_currency has no fallback either. Whether a rate
  # SOURCE carries the currency is a separate question, asked by
  # Rates::CoverageProbe when the currency is added.
  test "every scheme files in a currency this installation knows" do
    TaxSchemeConfig.all_schemes.each do |scheme|
      currency = TaxSchemeConfig.currency_for(scheme)
      assert_includes CurrencyConfig.symbols.keys, currency,
                      "#{scheme} files in #{currency}, which is not a currency this installation has. " \
                      "Add it on the currencies screen before the tax category file."
    end
  end

  test "the British tax year end is read from the header, not from the code" do
    assert_equal "04-05", TaxSchemeConfig.tax_year_ends("gb")
  end

  test "a country that declares no tax year end keeps the calendar year" do
    assert_equal TaxSchemeConfig::DEFAULT_TAX_YEAR_END, TaxSchemeConfig.tax_year_ends("de")
    assert_equal TaxSchemeConfig::DEFAULT_TAX_YEAR_END, TaxSchemeConfig.tax_year_ends("ch")
    assert_equal TaxSchemeConfig::DEFAULT_TAX_YEAR_END, TaxSchemeConfig.tax_year_ends("ro")
  end

  # A tax year belongs to the COUNTRY, so every scheme filed there shares it.
  # The config reads file by file and the last one wins, so two British files
  # disagreeing would leave the answer to alphabetical order.
  test "a country's files agree on when its tax year ends" do
    declared = Hash.new { |h, k| h[k] = {} }
    Dir.glob(Rails.root.join("db", "tax_categories", "*.yml")).each do |path|
      header  = YAML.safe_load_file(path)
      country = header["country_code"].to_s.downcase
      declared[country][File.basename(path)] = header["tax_year_ends"]
    end

    declared.each do |country, by_file|
      assert_equal 1, by_file.values.uniq.size,
                   "#{country} declares more than one tax year end: #{by_file.inspect}"
    end
  end

  test "a declared tax year end is a real MM-DD date" do
    Dir.glob(Rails.root.join("db", "tax_categories", "*.yml")).each do |path|
      value = YAML.safe_load_file(path)["tax_year_ends"]
      next if value.blank?

      assert_match(/\A\d{2}-\d{2}\z/, value.to_s,
                   "#{File.basename(path)} tax_year_ends must be MM-DD, got #{value.inspect}")
      month, day = value.to_s.split("-")
      # A leap year, so 02-29 is accepted and 02-31 is not.
      real = begin
        Date.new(2028, month.to_i, day.to_i)
      rescue ArgumentError
        nil
      end
      assert real, "#{File.basename(path)} tax_year_ends #{value.inspect} is not a real date"
    end
  end

  # What gets SENT is not the annual return it feeds: an MTD quarterly update
  # is not an SA105, and a button saying SA105 would suggest the annual return
  # had been filed, which this app never does.
  test "a scheme that can be filed declares what is actually submitted" do
    Dir.glob(Rails.root.join("db", "tax_categories", "*.yml")).each do |path|
      header = YAML.safe_load_file(path)
      next if header["connector"].blank?

      assert header["submission_name"].present?,
             "#{File.basename(path)} declares a connector, so it must say what is " \
             "submitted — otherwise the link falls back to the report's name"
    end
  end

  test "submission_name falls back to the report name when none is declared" do
    assert_equal "DE-EÜR", TaxSchemeConfig.submission_name_for("de_euer")
    assert_equal "MTD property", TaxSchemeConfig.submission_name_for("gb_property")
  end

  # PayloadBuilder drops a category with no api_field, so the money would
  # vanish between the report and the authority with nothing on screen to show
  # for it, and the submission would still be accepted. Read from the YAML
  # rather than the loaded rows, to catch a catalogue before anyone runs
  # acc:tax_categories:load.
  test "every category of a filable scheme has an api_field" do
    Dir.glob(Rails.root.join("db", "tax_categories", "*.yml")).each do |path|
      header = YAML.safe_load_file(path)
      next if header["connector"].blank?

      missing = Array(header["categories"]).reject { |c| c["api_field"].present? }
      assert_empty missing.map { |c| c["key"] },
                   "#{File.basename(path)} declares connector " \
                   "#{header['connector'].inspect}, so every category needs an api_field — " \
                   "one without it is silently dropped from the submission"
    end
  end
end
