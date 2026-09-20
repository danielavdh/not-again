# frozen_string_literal: true

module TaxpayersHelper
  # Every authority the app can actually file with, for the picker. Derived from
  # the built connectors, not from the catalogue headers: a country may name an
  # authority we cannot reach, and there is nothing to register with an
  # authority that has no connector.
  def authority_options
    Filing::Base::CONNECTORS
      .filter_map { |c| Filing::Base.connector_class(c) }
      .map { |klass| [ TaxSchemeConfig.authority_for_connector(klass.connector),
                       klass.authority_key ] }
      .uniq
      .sort_by(&:first)
  end
end
