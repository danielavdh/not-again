# frozen_string_literal: true

module Rates
  # What the manual rate fetcher offers, named by the AUTHORITY that accepts a
  # feed rather than only by the publisher. An admin arriving at this screen is
  # thinking "my German VAT return has no rates", not "the Bundesbank series has
  # a gap": they know who their tax boss is, and may not know which central bank
  # that authority points at.
  #
  # One row per (authority, source), not per authority, because one publisher
  # serves several countries: the Netherlands and Spain both accept the ECB
  # daily series, so both appear, and both options carry the SAME VALUE — the
  # source key. Selecting either fetches once. The duplication is in the
  # presentation, where it helps, and not in the work.
  #
  # A source no rule claims is still listed, under its publisher: an
  # installation with an empty rules file still needs the ECB, because tier 1
  # converts before any tax rule is involved.
  #
  # NOT in RateSourceConfig, which is tier 1 and must not read the rules file.
  # The split is by USAGE, and keeping tier 1 country-free is the point of the
  # tier.
  module FetchOptions
    # [[label, source_key], ...] for a select. Authorities first,
    # alphabetically;
    # then any publisher no authority has claimed.
    def self.call
      claimed = []

      by_authority = rules_by_authority.flat_map { |authority, sources|
        sources.map { |source|
          claimed << source
          [ label(authority, source), source ]
        }
      }.sort_by(&:first)

      # The long label alone. full_label_for appends the short one for tight
      # spaces, which here would produce "ECB (daily) (ECB/d)" — the bracket in
      # these rows is reserved for the authority, and an unclaimed source has
      # none.
      unclaimed = (RateSourceConfig.all - claimed).map { |source|
        [ RateSourceConfig.label_for(source), source ]
      }

      by_authority + unclaimed
    end

    # "ELSTER (BMF)", and just "HMRC" where the authority IS the publisher. Two
    # of the four shipped feeds are published by the tax authority itself, so
    # "HMRC (HMRC)" would be the common case rather than a curiosity.
    def self.label(authority, source)
      publisher = RateSourceConfig.short_label_for(source)
      return authority if publisher.casecmp?(authority.to_s)

      "#{authority} (#{publisher})"
    end
    private_class_method :label

    # authority name => the sources its countries accept, in the order the
    # rules give them. An authority with two countries behind it appears once.
    def self.rules_by_authority
      RateRuleConfig.all.each_with_object({}) do |country, out|
        authority = TaxSchemeConfig.authority(country).presence || country.to_s.upcase
        sources   = RateRuleConfig.accepted_sources(country) +
                    scheme_sources(country)

        out[authority] = ((out[authority] || []) + sources).uniq
                           .select { |s| RateSourceConfig.exists?(s) }
      end
    end
    private_class_method :rules_by_authority

    # A country's per-tax overrides name sources its top-level rule does not —
    # Germany's VAT block is the live case, and the Bundesbank would otherwise
    # appear under no authority at all.
    def self.scheme_sources(country)
      RateRuleConfig.overridden_schemes(country).flat_map { |scheme|
        RateRuleConfig.accepted_sources(country, scheme: scheme)
      }
    end
    private_class_method :scheme_sources
  end
end
