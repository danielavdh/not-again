# frozen_string_literal: true

module EntitiesHelper
  # The tax authorities this entity can actually submit to: one entry per
  # authority behind a scheme that has a filing connector, each carrying the
  # display name and the id of the submission <section> to deep-link to.
  #
  # An array, not a single value: the authority follows the SCHEME, so an entity
  # filing in two countries has two. Empty when nothing is submittable.
  #
  # The connector travels with the entry. A view asking "can this entity file
  # through the MTD connector?" must ask for the CONNECTOR, never the
  # authority's display name — renaming `authority:` in a YAML header would
  # otherwise hide the NINO and business-id fields with no error.
  def submission_authorities(entity)
    Array(entity.tax_schemes).filter_map { |scheme|
      connector = TaxSchemeConfig.connector_for(scheme)
      # Declared in the catalogue is not the same as built. A scheme naming an
      # authority we have no connector for stops at tier 2 — tagging and export
      # — and must not be offered a connect button.
      next unless Filing::Base.registered?(connector)
      country = TaxSchemeConfig.country_for(scheme)
      name    = TaxSchemeConfig.authority_for(scheme)
      next unless country && name
      { name: name, connector: connector, anchor: "#{country}_connection" }
    }.uniq
  end

  # Does this entity file through the given connector? The question every view
  # actually wants to ask.
  def files_via?(entity, connector)
    submission_authorities(entity).any? { |a| a[:connector] == connector }
  end

  # "Standard CSV" / "add DATEV". Phrased as an ADDITION because the standard
  # files always go too: the blank option is not "no export", it is "the
  # standard ones are fine". The format's own name stays untranslated inside the
  # wrapper; only the word "add" is a translation.
  #
  # NOT :format — I18n reserves it, along with :default, :scope and :locale, and
  # raises ReservedInterpolationKey rather than interpolating.
  def accountant_export_options
    AccountantExports::Base.options.map do |label, slug|
      [ t("tax.accountant_export_add", name: label), slug ]
    end
  end

  # The submission page for a scheme, or nil if nothing can submit it. The route
  # is the same whichever authority is behind it — the filing controller
  # resolves the connector — so the only question is whether one exists.
  def scheme_filing_path(entity, scheme)
    return unless Filing::Base.registered?(TaxSchemeConfig.connector_for(scheme))
    filing_periods_entity_path(entity, scheme: scheme)
  end

  def orphaned?(entity)
    "orphaned" if entity.orphaned?
  end

  # Heading label for a consolidated report: the entities (code + name) it
  # covers, shown as the business-family name when the selection is exactly one
  # whole family.
  def report_scope_label(codes)
    return "" if codes.blank?

    entities = Entity.where(code: codes).includes(:entity_group).order(:code)
    groups   = entities.filter_map(&:entity_group).uniq

    if groups.one? && groups.first.codes.sort == entities.map(&:code).sort
      "#{groups.first.name} (#{entities.map(&:code).join(', ')})"
    else
      entities.map { |e| "#{e.code} #{e.name}" }.join(", ")
    end
  end

end
