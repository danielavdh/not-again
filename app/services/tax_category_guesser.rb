# frozen_string_literal: true

# Suggests a tax category for an account by reading its NAME.
#
# Reading the name rather than the account code means the knowledge lives in the
# catalogue beside the box it describes, in the form's own language, and a new
# country needs no Ruby at all. A code-based guess could only ever be right if
# the account had been numbered to a convention nothing enforces.
#
# LANGUAGE: the form's, never the user's. A German Vermietung box is not
# "service charges" in any language. An account named in one language will not
# match a catalogue written in another, and that is the accepted limit — a
# missing suggestion costs one pick from a dropdown.
class TaxCategoryGuesser
  # Below this, a keyword must match a whole word. "rate" as a substring finds
  # "corporate"; "miete" finds "Büromiete", which is the whole point in a
  # language that builds compounds.
  SUBSTRING_MINIMUM = 4

  def self.for_scheme(scheme, year: nil)
    new(scheme: scheme, year: year)
  end

  # Punctuation out, spaces normalised, so "Rent, rates & insurance" and "rent
  # rates insurance" are the same string. BOTH sides go through it — the loader
  # normalises keywords with this too, or "kfz-nutzung" could never match a name
  # whose hyphen had already become a space.
  def self.normalise(text)
    text.to_s.downcase.gsub(/[^[[:alnum:]]]+/, " ").strip
  end

  def initialize(scheme:, year: nil)
    @scheme = scheme.to_s
    @year   = year
  end

  # nil, or the key of the single best-matching category. Best is [how many
  # keywords hit, how much of the name they covered], in that order: the second
  # is what makes the SPECIFIC box win, since "Kfz-Versicherung" matches both
  # "versicherung" and "kfz versicherung" once each and the longer phrase is the
  # one that means it.
  #
  # A TIE IS STILL NO ANSWER. Two categories fitting equally well is exactly
  # when a confident wrong guess is expensive, and saying nothing costs one pick
  # from a dropdown.
  def guess(name)
    scored = scores(name)
    return nil if scored.empty?

    best = scored.values.max
    winners = scored.select { |_key, score| score == best }.keys
    winners.one? ? winners.first : nil
  end

  # { account_id => key } for many accounts, over one pass of the catalogue.
  # The categories are loaded once, not once per account.
  def guess_all(accounts)
    return {} if categories.empty?

    accounts.each_with_object({}) do |account, found|
      key = guess(account.name)
      found[account.id] = key if key
    end
  end

  private

  attr_reader :scheme, :year

  # key => [number of keywords hit, characters they covered]. Arrays compare
  # element by element, so the count decides and the length only breaks a draw.
  # Categories with no keywords, and those that match nothing, are absent.
  def scores(name)
    haystack = self.class.normalise(name)
    return {} if haystack.empty?

    categories.each_with_object({}) do |category, found|
      hits = category.keywords.select { |word| matches?(haystack, word) }
      found[category.key] = [ hits.size, hits.sum(&:length) ] if hits.any?
    end
  end

  def matches?(haystack, word)
    return false if word.blank?
    return haystack.include?(word) if word.length >= SUBSTRING_MINIMUM

    haystack.split(" ").include?(word)
  end

  # The catalogue for this scheme at the effective year — the same resolution
  # the reports use, so a suggestion can never come from an edition a submission
  # would not.
  def categories
    @categories ||= begin
      effective = TaxCategory.where(scheme: scheme)
                             .where(year ? [ "tax_year <= ?", year ] : "TRUE")
                             .maximum(:tax_year)
      effective ? TaxCategory.where(scheme: scheme, tax_year: effective).to_a : []
    end
  end
end
