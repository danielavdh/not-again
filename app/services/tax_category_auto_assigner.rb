# frozen_string_literal: true

# The bulk preview: what TaxCategoryGuesser would suggest for every untagged
# account of one entity. Never writes — assigning is a confirmation the
# bookkeeper makes on the scheme's own page, one account at a time.
#
# Asked per SCHEME, not per country, so a mixed-country entity is served:
# reading the account CODE could not say which catalogue was meant, since the
# same digit means different things in Germany and Britain. Names carry their
# own language.
class TaxCategoryAutoAssigner
  Result = Struct.new(:assigned, :skipped_non_taggable, :skipped_no_guess,
                      :skipped_already_set, keyword_init: true)

  def self.call(entity_code:, dry_run: true)
    new(entity_code: entity_code, dry_run: dry_run).call
  end

  def initialize(entity_code:, dry_run:)
    @entity_code = entity_code
    @dry_run     = dry_run
  end

  def call
    entity = Entity.find_by(code: @entity_code)
    abort_with "Entity #{@entity_code} not found" unless entity

    schemes = Array(entity.tax_schemes)
    abort_with "Entity #{@entity_code} files no tax schemes — pick them first" if schemes.empty?

    result = Result.new(assigned: 0, skipped_non_taggable: 0, skipped_no_guess: 0,
                        skipped_already_set: 0)

    puts "[PREVIEW] Suggestions for entity #{@entity_code} (#{schemes.join(', ')}) — nothing is saved"

    # One guesser per scheme, each loading its catalogue once.
    guessers = schemes.to_h { |scheme| [ scheme, TaxCategoryGuesser.for_scheme(scheme) ] }

    Account.for_entity_codes([ @entity_code ])
                .find_each(batch_size: 200) do |account|
      unless account.tax_taggable?
        result.skipped_non_taggable += 1
        next
      end
      if account.tax_category_key.present?
        result.skipped_already_set += 1
        next
      end

      # Every scheme this entity files, so a mixed-country entity is served. Two
      # schemes both claiming one account is the same tie the guesser refuses
      # within a scheme, and for the same reason.
      hits = guessers.filter_map { |scheme, guesser|
        key = guesser.guess(account.name)
        [ scheme, key ] if key
      }

      unless hits.one?
        result.skipped_no_guess += 1
        puts "  ? #{account.code} #{account.name} — #{hits.empty? ? 'no guess' : 'more than one scheme fits'}"
        next
      end

      scheme, key = hits.first
      puts "  ✓ #{account.code} #{account.name} → #{scheme}.#{key}"
      result.assigned += 1
    end

    puts "\nSummary (preview only — confirm assignments on the dashboard):"
    puts "  Suggestions ready:   #{result.assigned}"
    puts "  Skipped (not I/E):   #{result.skipped_non_taggable}"
    puts "  Already assigned:    #{result.skipped_already_set}"
    puts "  No suggestion:       #{result.skipped_no_guess}"
    result
  end

  private

  def abort_with(msg)
    raise ArgumentError, msg
  end
end
