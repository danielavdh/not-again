# frozen_string_literal: true

# Single source of truth for which countries and schemes the app knows about.
# Everything is read from the YAML headers in db/tax_categories — nothing is
# hardcoded here or on Entity — so adding a country or a scheme is a matter of
# dropping in a YAML file.
#
# Recognised header keys:
# country_code:    two-letter code, lowercased
# scheme:          a plain word for the scheme, in its own language
# ("vermietung", "self_employment"). Need only be distinct WITHIN its own
# country's files, and is never typed with a prefix: everywhere else in the app
# uses the SLUG, "#{country_code}_#{scheme}", built here and globally unique by
# construction.
# authority:       tax authority the country files with (HMRC / ELSTER / ESTV)
# connector:       the Filing class that submits it, if it can be submitted
# digitally. Omitted = tagging and export only.
# scheme_label:    what the scheme is CALLED, in its form's own language
# report_name:     what its tax REPORT is called
# submission_name: what is actually SENT, for schemes with a connector
# form_code:       the authority's reference for the form (names the archive)
# currency:        what the scheme's figures are denominated in
# tax_year_ends:   "MM-DD" — omit for a calendar year
# position:        display order of the scheme within its country (optional)
#
# Four of those are NAMES answering four different questions. Adding a fifth is
# a smell; picking the wrong one of the four is a bug users can see:
# scheme_label    "UK Property (SA105)"  the form you tag against
# report_name     "GB-property"          our report over those accounts
# submission_name "MTD property"         what is actually transmitted
# form_code       "SA105"                names the archived document
#
# Files are read once and memoised. Call .reload! after changing them in a
# console; in development a restart picks them up.
module TaxSchemeConfig
  CONFIG_DIR = Rails.root.join("db", "tax_categories")
  DEFAULT_POSITION = 999
  # A calendar year. Stated as a date rather than assumed, so that the one rule
  # in TaxCategory.tax_year_for covers every country — see .tax_year_ends.
  DEFAULT_TAX_YEAR_END = "12-31"

  # Every country the app has a catalogue for, sorted.
  def self.countries
    config[:countries]
  end

  def self.schemes_by_country
    config[:schemes_by_country]
  end

  def self.schemes_for(country_code)
    schemes_by_country.fetch(country_code.to_s.downcase, [])
  end

  # "HMRC" / "ELSTER" / "ESTV", or nil when the country's files declare none.
  def self.authority(country_code)
    config[:authorities][country_code.to_s.downcase]
  end

  # The day a tax year ENDS, as "MM-DD". Declared per country in the header of
  # its tax category files; "12-31" when none says otherwise.
  #
  # One field covers both cases rather than an enum, because a calendar year IS
  # a year ending 31 December: the rule "the tax year is named by the year it
  # ends in" then produces 2028 for a German date in 2028 and 2029 for a British
  # date in July 2028, with no branch. Ireland, India and Australia become a
  # header line instead of an `if`.
  def self.tax_year_ends(country_code)
    config[:tax_year_ends][country_code.to_s.downcase] || DEFAULT_TAX_YEAR_END
  end

  # A scheme SLUG is unique across countries BY CONSTRUCTION — always
  # "#{country_code}_#{scheme}", never a bare word a contributor had to remember
  # to prefix. That is what lets a scheme name its own country, and what lets
  # one entity carry schemes from more than one country: nothing has to read the
  # entity's tax_country_code to work out which catalogue, authority or
  # connector applies.
  #
  # Every argument called `scheme` below, and everywhere outside this file, IS
  # the slug — never the bare word from a YAML header. The bare word only exists
  # inside .build, for the one line that combines it with country_code.

  def self.country_for(scheme)
    config[:countries_by_scheme][scheme.to_s]
  end

  def self.authority_for(scheme)
    country = country_for(scheme)
    country && authority(country)
  end

  # Which filing connector handles this scheme, or nil when it stops at
  # account tagging and CSV export.
  def self.connector_for(scheme)
    config[:connectors][scheme.to_s]
  end

  # The authority a CONNECTOR files with, for the places that hold a connector
  # but no scheme — above all the OAuth callback, which comes back from the
  # authority knowing only which connector sent it there.
  def self.authority_for_connector(connector)
    config[:authorities_by_connector][connector.to_s]
  end

  # Where this catalogue's figures came from: the authority's own form, its
  # checksum, the year of the edition used, and the page that lists editions.
  # nil for a scheme built from statute rather than a form (Switzerland). Every
  # key inside is optional — declare what can actually be verified.
  def self.source_for(scheme)
    config[:sources][scheme.to_s]
  end

  # What the SCHEME is called, in the language of the form it belongs to — "UK
  # Property (SA105)", "Vermietung und Verpachtung (Anlage V)". The name a user
  # picks from when subscribing, and the one every message about a scheme
  # interpolates.
  #
  # NOT TRANSLATED. A tax form's name is not a thing that translates: anyone
  # filling in an Anlage V is looking at a form that says Anlage V. As a locale
  # key it was the same five strings copied into four files.
  #
  # The practical gain is the point of tier 2: a contributor adding a country
  # names their scheme in their own file, in their own language, instead of
  # needing four locale files edited by someone else.
  #
  # Falls back to the slug humanised, so a file that omits it still reads.
  def self.scheme_label(scheme)
    config[:scheme_labels][scheme.to_s].presence || scheme.to_s.humanize
  end

  # The tax report's visible name — "GB-self-employment", "DE-EÜR", "CH-Selbst".
  # Declared, never derived and never translated: capitalisation follows the
  # scheme's own language, which no rule can infer from the slug.
  def self.report_name(scheme)
    config[:report_names][scheme.to_s]
  end

  # What the app actually SENDS for this scheme — "MTD property", not the annual
  # return it feeds. Deliberately not report_name, which names the report, and
  # not scheme_label, which names the form you TAG against. Under MTD you send
  # quarterly updates and confirm the year separately, so a button saying SA105
  # would suggest the annual return had been filed, which this app never does.
  #
  # Falls back to the report name for a scheme that declares none.
  def self.submission_name_for(scheme)
    config[:submission_names][scheme.to_s].presence || report_name(scheme)
  end

  # The currency the scheme files in, and the one a tax report totals into. The
  # user does not choose it — unlike a custom report, where they may.
  def self.currency_for(scheme)
    config[:currencies][scheme.to_s]
  end

  # The authority's own reference for the FORM this scheme feeds — "SA103",
  # "SA105", "AnlageV". Used to name an archived submission, so a stored
  # document says what it belongs to in the authority's language rather than in
  # ours.
  #
  # Not report_name, which names our report, and not submission_name, which
  # names what was sent: three names because they answer three questions, and a
  # filename wants the one an accountant would recognise on a folder listing.
  #
  # Optional: Filing::Storage falls back to the upcased slug.
  def self.form_code_for(scheme)
    config[:form_codes][scheme.to_s]
  end

  # Every scheme the app knows, in country then declared-position order.
  def self.all_schemes
    config[:countries].flat_map { |c| schemes_for(c) }
  end

  def self.reload!
    @config = nil
  end

  def self.config
    @config ||= build
  end

  # Sorted glob, so when several tax years declare the same scheme the newest
  # file's header wins.
  #
  # Two files declaring the exact same country_code/scheme/tax_year is not "the
  # newest wins", it is an error — nothing legitimate produces that, only a
  # copy-paste mistake or a genuine slug collision. RAISES rather than picking
  # one silently, and does it here so it fires the moment .config is first read.
  def self.build
    connectors       = {}
    authorities      = {}
    report_names     = {}
    scheme_labels    = {}
    submission_names = {}
    currencies   = {}
    form_codes   = {}
    sources      = {}
    tax_year_ends = {}
    positions    = Hash.new { |h, k| h[k] = {} }
    seen_headers = {}

    Dir.glob(CONFIG_DIR.join("*.yml")).sort.each do |path|
      data = YAML.safe_load_file(path)
      next unless data.is_a?(Hash)

      country = data["country_code"].to_s.downcase
      scheme  = data["scheme"].to_s
      next if country.empty? || scheme.empty?

      # The one place a bare scheme word and a country_code combine — every
      # other lookup in this file, and everywhere outside it, uses this slug.
      slug = "#{country}_#{scheme}"

      header = [ country, scheme, data["tax_year"].to_s ]
      if (earlier = seen_headers[header])
        raise "#{path} declares the same country_code/scheme/tax_year as " \
              "#{earlier} (#{header.join('/')}). Two files must never claim " \
              "to be the same catalogue — if the scheme itself is new, its " \
              "`scheme:` word needs to differ from the existing one in this " \
              "country's other files."
      end
      seen_headers[header] = path

      connectors[slug]            = data["connector"].presence
      authorities[country]        = data["authority"].presence if data["authority"].present?
      report_names[slug]          = data["report_name"].presence
      scheme_labels[slug]         = data["scheme_label"].presence
      submission_names[slug]      = data["submission_name"].presence
      currencies[slug]            = data["currency"].presence&.upcase
      form_codes[slug]            = data["form_code"].presence
      sources[slug]                = data["source"].presence
      positions[country][slug]    = (data["position"] || DEFAULT_POSITION).to_i
      # Per COUNTRY, not per scheme: a tax year is a fact about the country's
      # calendar, and every scheme filed there shares it. A test enforces that a
      # country's files agree, so last-file-wins never silently decides it.
      tax_year_ends[country]      = data["tax_year_ends"].presence if data["tax_year_ends"].present?
    end

    schemes_by_country = positions.transform_values { |by_slug|
      by_slug.sort_by { |slug, position| [ position, slug ] }.map(&:first).freeze
    }.freeze

    countries_by_scheme = schemes_by_country.each_with_object({}) do |(country, slugs), h|
      slugs.each { |slug| h[slug] = country }
    end.freeze

    # A connector serves one authority, so this collapses safely: every GB
    # scheme with connector hmrc_mtd names HMRC. Built here rather than looked
    # up twice at call time.
    authorities_by_connector = connectors.each_with_object({}) do |(slug, name), h|
      country = countries_by_scheme[slug]
      h[name] = authorities[country] if name && country && authorities[country]
    end.freeze

    {
      connectors:               connectors.freeze,
      authorities:              authorities.freeze,
      authorities_by_connector: authorities_by_connector,
      sources:                  sources.freeze,
      tax_year_ends:            tax_year_ends.freeze,
      report_names:             report_names.freeze,
      scheme_labels:            scheme_labels.freeze,
      submission_names:         submission_names.freeze,
      currencies:               currencies.freeze,
      form_codes:               form_codes.freeze,
      schemes_by_country:       schemes_by_country,
      countries_by_scheme:      countries_by_scheme,
      countries:                schemes_by_country.keys.sort.freeze
    }.freeze
  end
  private_class_method :build
end
