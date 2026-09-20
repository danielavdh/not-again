# frozen_string_literal: true

# Tells the bookkeepers whose accounts have just lost their tax category.
#
# Accounts point at categories by plain string, with no foreign key, so when a
# catalogue file drops a key the loader deletes those rows and every account
# tagged with it stops resolving — with nothing on screen to say so. The account
# is not blank, so it does not appear in the "needs tagging" list, and the
# export and the HMRC payload both skip a category they cannot find. The figure
# simply leaves the return.
#
# This job is what makes the deletion audible: each admin who can actually fix
# it is told which of THEIR accounts to re-tag. Only full_access links are
# notified — a read_only or upload_receipts coadmin cannot re-tag an account, so
# telling them is noise.
class TaxCategoryRemovalNotificationJob < ApplicationJob
  queue_as :default

  def perform(scheme:, tax_year:, removed_keys:)
    keys = Array(removed_keys).compact.uniq
    return if scheme.blank? || keys.empty?

    # Ids and codes only — never the records. This runs inside a catalogue
    # load, which may be reloading five files at once.
    affected = Account.where(tax_scheme: scheme, tax_category_key: keys)
                           .pluck(:code, :name, :tax_category_key)
    if affected.empty?
      Rails.logger.info(
        "TaxCategoryRemoval: #{keys.size} key(s) removed from #{scheme} #{tax_year}, no accounts were using them"
      )
      return
    end

    by_admin(affected).each do |admin, accounts|
      next if admin.email_address.blank?

      AdminMailer.with(
        admin:        admin,
        scheme:       scheme,
        tax_year:     tax_year,
        accounts:     accounts.sort_by(&:first),
        removed_keys: keys
      ).tax_categories_removed.deliver_now
    end
  end

  private

  # An account's entity is the second and third digit of its code, so the route
  # from a stranded account to the person who can fix it is code → entity →
  # full_access link → admin.
  def by_admin(affected)
    by_entity_code = affected.group_by { |(code, *)| code.to_s[1, 2] }

    entity_ids = Entity.where(code: by_entity_code.keys).pluck(:id, :code).to_h
    return {} if entity_ids.empty?

    links = AdminEntity.with_full_access
                            .where(entity_id: entity_ids.keys)
                            .pluck(:admin_id, :entity_id)
    return {} if links.empty?

    admins = Admin.where(id: links.map(&:first).uniq).index_by(&:id)

    links.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(admin_id, entity_id), out|
      admin = admins[admin_id]
      next if admin.nil?

      rows = by_entity_code[entity_ids[entity_id]] || []
      out[admin].concat(rows)
    end
  end
end
