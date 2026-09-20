# frozen_string_literal: true

# One taxpayer as ONE AUTHORITY knows them: their number, and their permission
# for this app to act for them.
#
# Not one human. Someone filing in the UK and in Germany has two numbers and two
# permissions, so two taxpayers, and nothing links them. Nothing in filing needs
# the link either: a tax report group has one scheme, a scheme has one
# authority, so a group needs exactly one taxpayer.
#
# It belongs to an ADMIN and is CHOSEN per tax report group, which is what lets
# one taxpayer with several entities authorise once.
#
# Business identifiers are NOT here. HMRC issues one per trade, so they belong
# to the group whose accounts are that trade. This holds only what identifies
# the PERSON.
class Taxpayer < ApplicationRecord

  # optional: the admin is the CREATOR, and a taxpayer still filing for an
  # entity outlives them (Admin#release_or_destroy_taxpayers). Who may USE it is
  # Admin#usable_taxpayers, which asks the entities, not this column.
  belongs_to :admin, optional: true
  has_many :report_groups, class_name: "ReportGroup",
           foreign_key: :taxpayer_id, dependent: :nullify

  # Only the tokens. The identifiers bag is deliberately in the clear — see the
  # migration for why: these identify, they do not grant.
  encrypts :access_token, :refresh_token

  validates :authority, presence: true
  validate  :identifiers_well_formed
  validate  :identifiers_free_within_reach

  # Attached to a report group means someone is still filing with it, and
  # dependent: :nullify would take their taxpayer away without saying so —
  # ready_to_file? would simply go false. Detach it everywhere first.
  #
  # prepend, or it never fires: dependent: :nullify is itself a before_destroy
  # registered where the association is declared, so without this it would clear
  # taxpayer_id first and leave nothing for #in_use? to find.
  before_destroy :ensure_not_in_use, prepend: true

  scope :for_authority, ->(authority) { where(authority: authority.to_s) }

  # Rows holding this value for this identifier — a jsonb key lookup, no
  # scanning and nothing loaded.
  scope :with_identifier, ->(key, value) {
    where("identifiers ->> ? = ?", key.to_s, value.to_s)
  }

  # Connected means we hold a token. Whether it still works is a separate
  # question — see #expired?.
  def connected?
    access_token.present?
  end

  def expired?
    token_expires_at.present? && token_expires_at <= Time.current
  end

  # The authority's own name — "HMRC", "ELSTER". Stored as a key ("hmrc") and
  # displayed from the catalogue headers, which is where authorities are named.
  def authority_name
    connector = Filing::Base.connectors_for_authority(authority).first
    (connector && TaxSchemeConfig.authority_for_connector(connector.connector)) ||
      authority.to_s.upcase
  end

  # Which identifiers this authority wants for a taxpayer — HMRC asks for a
  # NINO, another will ask for something else. The form renders one field per
  # key.
  def identifier_keys
    Filing::Base.identifiers_for_authority(authority)
  end

  # What an admin sees when choosing between taxpayers. Falls back to the
  # authority rather than to the number: a list of NINOs would put personal data
  # on screen for the sake of a label.
  def display_name
    label.presence || authority_name
  end

  # Named methods rather than callers reaching into the hash, so the shape of
  # the bag stays this class's business.

  def identifier(key)
    identifiers[key.to_s].presence
  end

  # The identifier with all but its last character hidden — "••••••••C". Enough
  # to tell two apart and confirm the tail, without a full NINO sitting on a
  # list.
  def masked_identifier(key)
    value = identifier(key)
    return if value.blank?

    value.sub(/.+(?=.\z)/) { "•" * Regexp.last_match(0).length }
  end

  # Normalisation is the CONNECTOR's business — HMRC will not match "ab 12 34 56
  # c", and only the HMRC connector knows that. Callers hand over a value
  # already in the right shape.
  def set_identifier(key, value)
    bag = identifiers.dup
    value.presence ? bag[key.to_s] = value : bag.delete(key.to_s)
    self.identifiers = bag
  end

  # Ends the permission. The number stays: it belongs to the person, not to
  # the session, and they will need it again to reconnect.
  def clear!
    update!(access_token: nil, refresh_token: nil, token_expires_at: nil)
  end

  def in_use?
    report_groups.exists?
  end

  # The entities still filing with this taxpayer, as codes, for the message
  # that explains why it will not delete. One DISTINCT query, nothing loaded.
  def entity_codes_in_use
    Entity.where(id: report_groups.select(:entity_id))
               .distinct.order(:code).pluck(:code)
  end

  private

  # Only what the connector knows a shape for; everything else passes. A blank
  # number is allowed on purpose — a bookkeeper may have the client before the
  # paperwork, and Connect is where it genuinely cannot proceed without one.
  def identifiers_well_formed
    return if authority.blank?

    Filing::Base.identifiers_for_authority(authority).each do |key|
      value = identifier(key)
      next if value.blank?
      next if Filing::Base.valid_identifier_for_authority?(authority, key, value)

      errors.add(:base, I18n.t("filing.register.identifier_invalid",
                               identifier: I18n.t("filing.identifiers.#{key}",
                                                  default: key.to_s.upcase)))
    end
  end

  # Within reach, not globally. Two bookkeepers who share no entity may each
  # hold a row for the same person — separate arrangements with the authority —
  # and a global rule would both block the second and, by saying "already
  # registered", tell them someone else's client is here.
  #
  # What it does catch is the one that matters: an admin creating a second row
  # for a taxpayer already sitting in their own picker.
  def identifiers_free_within_reach
    return if admin.nil? || authority.blank?

    Filing::Base.identifiers_for_authority(authority).each do |key|
      value = identifier(key)
      next if value.blank?

      clash = admin.usable_taxpayers
                   .for_authority(authority)
                   .where.not(id: id)
                   .with_identifier(key, value)
                   .exists?
      next unless clash

      errors.add(:base, I18n.t("filing.register.identifier_taken",
                               identifier: I18n.t("filing.identifiers.#{key}",
                                                  default: key.to_s.upcase)))
    end
  end

  def ensure_not_in_use
    return unless in_use?

    errors.add(:base, I18n.t("filing.register.still_in_use"))
    throw(:abort)
  end
end
