# frozen_string_literal: true

module AccountantExports
  # An accountant export is an EXTRA file, in some accountancy profession's own
  # format, sent alongside the two everybody already gets: the transactions
  # listing with receipt links, and — for a tax report — the tax-category CSV.
  # So "none" is not "no export": it means the standard files are fine.
  #
  # Adding a format: write app/services/accountant_exports/<slug>.rb subclassing
  # Base with `label`, `filename` and `generate`, then add the slug to FORMATS
  # below. Nothing else — the setting on the entity, the dropdown on the tax
  # setup page and the export job all read this registry.
  #
  # FORMATS is explicit rather than derived from `subclasses` because Rails
  # autoloads: a class nobody has referenced yet does not exist yet, so
  # subclasses would return whatever happened to be loaded.
  #
  # The four arguments below are all any format gets, and they are deliberately
  # not DATEV-shaped: the postings in the period, the entity, and the dates. A
  # format needing anything else should derive it rather than grow the
  # interface.
  class Base
    FORMATS = %w[datev].freeze

    class << self
      def all
        FORMATS.filter_map { |slug| self.for(slug) }
      end

      # Labels are NOT translated — "DATEV" is a product name, and a format
      # called something else in German would send someone looking for a menu
      # item their accountant has never heard of.
      def options
        all.map { |format| [ format.label, format.slug ] }
      end

      # Resolved against the enclosing MODULE, not against Base: the formats are
      # siblings of Base, not nested inside it, so const_get on Base would miss
      # them and quietly return nothing.
      #
      # `false` = do not search ancestors. Without it const_get falls back to
      # Object, so a slug of "string" would resolve to ::String.
      def for(slug)
        return nil if slug.blank?
        return nil unless FORMATS.include?(slug.to_s)
        AccountantExports.const_get(slug.to_s.camelize, false)
      rescue NameError
        nil
      end

      def slug
        name.demodulize.underscore
      end

      def label
        raise NotImplementedError, "#{name} must define .label"
      end

      def filename
        raise NotImplementedError, "#{name} must define .filename"
      end
    end

    def initialize(postings:, entity:, start_date:, end_date:)
      @postings   = postings
      @entity     = entity
      @start_date = start_date
      @end_date   = end_date
    end

    def generate
      raise NotImplementedError, "#{self.class.name} must define #generate"
    end

    private

    attr_reader :postings, :entity, :start_date, :end_date
  end
end
