# frozen_string_literal: true

# A VAT code: a rate, a direction, and the two boxes of a return the net and tax
# amounts belong in. Catalogue data like TaxCategory, loaded from the scheme's
# YAML.
#
# Versioned by DATE, not by tax year: German VAT fell 19→16 on 1 July 2020 and
# back on 1 January 2021, so one tax year held two rates. Codes resolve by
# entry_date.
class TaxCode < ApplicationRecord
  INPUT      = "input"   # VAT we paid and may reclaim
  OUTPUT     = "output"  # VAT we charged and owe
  DIRECTIONS = [ INPUT, OUTPUT ].freeze

  # What the flat rate does with a code. Nil is inside the scheme: a sale feeds
  # the flat-rate turnover, a purchase reclaims nothing. The rest are the three
  # things Notice 733 does with a supply outside the scheme:
  #   normal       — boxes exactly as under normal rules (reverse charge on
  #                  services, a sale outside the scope)
  #   declare_only — the output half is declared, nothing is reclaimed
  #                  (postponed import VAT, a Northern Ireland acquisition)
  #   excluded     — nothing at all (import VAT paid at the border)
  FLAT_RATE_TREATMENTS = %w[normal declare_only excluded].freeze

  has_many :postings, dependent: :restrict_with_error

  validates :country_code, presence: true, format: { with: /\A[a-z]{2}\z/ }
  validates :scheme,       presence: true, format: { with: /\A[a-z][a-z0-9_]*\z/ }
  validates :key,          presence: true, format: { with: /\A[a-z][a-z0-9_]*\z/ }
  validates :key,          uniqueness: { scope: [:country_code, :scheme, :valid_from] }
  validates :direction,    inclusion: { in: DIRECTIONS }
  # 0% is a real rate with a real box: an export, a zero-rated supply.
  validates :rate_bps, numericality: { only_integer: true,
                                       greater_than_or_equal_to: 0,
                                       less_than_or_equal_to: 10_000 }
  validates :valid_from, presence: true
  validates :flat_rate, inclusion: { in: FLAT_RATE_TREATMENTS }, allow_nil: true
  validate  :valid_to_after_valid_from

  scope :for_schemes, ->(schemes) { where(scheme: Array(schemes)) }
  scope :on,          ->(date)    { where(valid_from: ..date)
                                      .where("valid_to IS NULL OR valid_to >= ?", date) }
  scope :ordered,     ->          { order(:scheme, :position, :key) }

  # The row of this key in force on a date. Nil is an answer, not a failure: a
  # code introduced in 2027 cannot be used in 2026.
  def self.resolve(scheme:, key:, on:)
    return nil if [ scheme, key, on ].any?(&:blank?)
    for_schemes(scheme).where(key: key).on(on).first
  end

  # One query for a whole entry's codes, so deriving a twelve-row entry costs
  # one, not twelve.
  def self.lookup(ids, on:)
    ids = Array(ids).compact.uniq
    return {} if ids.empty? || on.blank?
    where(id: ids).on(on).index_by(&:id)
  end

  # The `on` scope's test, for a code already in hand.
  def on?(date)
    return false if date.blank? || valid_from.blank?
    valid_from <= date && (valid_to.nil? || valid_to >= date)
  end

  def input?  = direction == INPUT
  def output? = direction == OUTPUT

  # A code with no rate, a tax box and no net box: the amount entered IS the
  # tax. Import VAT paid at the border — the goods were bought in their own
  # entry, and this payment is nothing but VAT, worked out by customs on a
  # value that is not the supplier's invoice. Nothing to split, nothing to type.
  def amount_is_tax?
    rate_bps.to_i.zero? && tax_category_key.present? && net_category_key.blank?
  end

  # The VAT a GROSS amount contains: 19% of 119.00 is 19.00, not 22.61, because
  # the user types what the statement says. Integer minor units throughout.
  #
  # half: :up is stated because Ruby's default rounds a tie to even, which would
  # take 0.5 down half the time.
  def tax_from_gross(gross)
    return 0 if rate_bps.zero?
    Rational(gross.to_i * rate_bps, 10_000 + rate_bps).round(half: :up)
  end

  # The VAT ON a net amount: reverse charge, where the invoice carries none.
  def tax_from_net(net)
    return 0 if rate_bps.zero?
    Rational(net.to_i * rate_bps, 10_000).round(half: :up)
  end

  # "19%", "7.5%", "0%" — trailing zeros dropped.
  def rate_label
    whole, fraction = (rate_bps / 100), (rate_bps % 100)
    fraction.zero? ? "#{whole}%" : "#{whole}.#{format('%02d', fraction).sub(/0\z/, '')}%"
  end

  # NOT translated: it names a line on one country's return, in that return's
  # language. Falls back to the key, whose slugs are already native.
  def label
    self[:label].presence || key.to_s.tr("_", " ").capitalize
  end

  # The rate only where it distinguishes: "Exempt (0%)" and "Zero rate (0%)"
  # read as the same thing, and they are not.
  def display_name = rate_bps.to_i.zero? ? label : "#{label} (#{rate_label})"

  # GROUPED by direction, for grouped_options_for_select. Flat, "Sale, reduced
  # rate (5%)" and "Purchase, reduced rate (5%)" sat six rows apart with only
  # the first word between them, and picking the wrong one reported VAT paid as
  # VAT owed.
  #
  # The rate rides on the option so the browser can make the same split; the
  # server recomputes regardless. The scheme is named only when two authorities
  # are in play, where "20%" alone would not say which — as a flag, because the
  # authority's own name is 26 characters and the option has none to spare.
  def self.options_for(schemes:, on:)
    schemes = Array(schemes)
    label_scheme = schemes.size > 1

    rows  = for_schemes(schemes).on(on).ordered.to_a
    boxes = boxes_for(rows, on: on)

    codes = rows.map { |code|
      prefix = label_scheme ? "#{TaxSchemeConfig.flag_for(code.scheme)} " : ""
      [ code.direction,
        "#{prefix}#{code.display_name}", code.id,
        { title: boxes[code.id],
          data: { rate_bps: code.rate_bps, direction: code.direction,
                  scheme: code.scheme,
                  reverse_charge: code.reverse_charge.presence,
                  amount_is_tax: code.amount_is_tax?.presence } } ]
    }

    # Purchases first — DIRECTIONS order — because most entries are money going
    # out, and the group a user reaches for should not be the second one.
    DIRECTIONS.filter_map { |direction|
      rows = codes.select { |d, *| d == direction }
      next if rows.empty?
      [ I18n.t("tax.vat.direction.#{direction}"), rows.map { |_d, *option| option } ]
    }
  end

  # Which boxes of the return a code's figures land in, as the authority words
  # them — the long wording the option label no longer has room for, and the
  # question a bookkeeper actually has about an unfamiliar code.
  #
  # Nothing is invented here: it is the label of the category the code already
  # names. A category with no box of its own (a feeder, carrying a figure the
  # authority computes itself) has nothing to say and is left out, so a German
  # sale shows Kz 81 alone — which is the truth about the UStVA.
  #
  # One query for all of them, however many codes.
  def self.boxes_for(codes, on:)
    keys = codes.flat_map { |c|
      [ c.net_category_key, c.tax_category_key, c.reverse_tax_category_key ]
    }.compact.uniq
    return {} if keys.empty?

    years = codes.map(&:country_code).uniq.index_with { |cc|
      TaxCategory.tax_year_for(country_code: cc, date: on)
    }
    categories = TaxCategory.where(scheme: codes.map(&:scheme).uniq, key: keys)
                            .where("tax_year <= ?", years.values.compact.max)
                            .order(:tax_year)
                            .index_by { |c| [ c.scheme, c.key ] }

    codes.index_by(&:id).transform_values { |code|
      lines = [ code.net_category_key, code.tax_category_key, code.reverse_tax_category_key ]
        .compact
        .filter_map { |key|
          category = categories[[ code.scheme, key ]]
          next if category.nil? || category.reference.blank?
          # Not a dash: the authority's own labels already contain one.
          "#{category.reference} · #{category.label}"
        }.uniq
      lines.join("\n").presence
    }
  end

  private

    def valid_to_after_valid_from
      return if valid_to.blank? || valid_from.blank? || valid_to >= valid_from
      errors.add(:valid_to, :greater_than_or_equal_to, count: valid_from)
    end
end
