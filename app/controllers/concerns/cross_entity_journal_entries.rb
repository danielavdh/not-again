# frozen_string_literal: true

# Shared cross-entity save: persists JE₁ plus each linked entry (JE₂, JE₃…),
# built from nested `cross_entity_entries` params, in ONE transaction. Included
# by BOTH the journal-entries controller and the accounts controller (bank
# entries), so a cross-entity transaction works from a JE or a bank entry.
#
# Model validations (mirror amount/side, balance, single-entity, the Posting
# link guard) enforce integrity; a linked-entry failure rolls the whole thing
# back and surfaces its errors on the origin entry for the form.
module CrossEntityJournalEntries
  extend ActiveSupport::Concern

  # Permitted posting fields — shared by an entry's OWN postings and by each
  # linked entry's postings, so JE₂/JE₃… carry full data including receipts.
  # The 3xx capital posting's cross_entity_link_id links it to JE₁'s 601 gift.
  POSTING_PARAMS = [
    :id, :account_id, :amount, :amount_display, :currency, :entry_type,
    :description, :reference, :_destroy, :existing_receipt_id,
    :deduction_pair_id, :deduction_percentage, :cross_entity_link_id,
    { receipts_attributes: [:id, :title, :receipt_date, :description,
                            :scan, :entity_id, :_destroy] }
  ].freeze

  private

  # --- write guard -------------------------------------------------------
  # A cross-entity transaction deliberately writes into a SECOND entity, so
  # both sides have to be writable by this admin — not merely accessible. Used
  # as a before_action by both controllers that include this concern; the check
  # itself lives in BaseController#require_writable_posting_accounts.

  def require_writable_submitted_accounts
    require_writable_posting_accounts(submitted_posting_account_ids)
  end

  # Every account id this submission aims a posting at: the entry's own
  # postings, each cross-entity leg's postings, and a transfer's two ends.
  def submitted_posting_account_ids
    root = params[:journal_entry]
    return [] if root.blank?

    ids = posting_account_ids_in(root[:postings_attributes])
    cross_entity_entries_params.each do |attrs|
      ids.concat(posting_account_ids_in(attrs[:postings_attributes]))
    end
    ids.concat([root[:from_account_id], root[:to_account_id]])
    ids.compact_blank.uniq
  end

  # postings_attributes arrives as a hash keyed by row index from a form, or as
  # an array from JSON. Both shapes, one reader.
  def posting_account_ids_in(attrs)
    return [] if attrs.blank?

    rows = attrs.respond_to?(:values) ? attrs.values : Array(attrs)
    rows.filter_map { |row| row[:account_id] if row.respond_to?(:[]) }
  end

  # Saves `journal_entry` and builds each cross-entity linked entry in one
  # transaction. No linked entries → a plain save (unchanged behaviour). Returns
  # true on success; on failure the origin entry carries the errors for the form.
  def save_with_cross_entity_entries(journal_entry)
    entries = cross_entity_entries_params
    return journal_entry.save if entries.empty?

    ActiveRecord::Base.transaction do
      # Both sides move together on a coupled edit; suppress the per-posting mirror
      # guard while writing, then re-verify once everything is persisted.
      Current.skip_cross_entity_consistency = true
      journal_entry.save!
      entries.each do |attrs|
        postings = attrs[:postings_attributes]
        existing = existing_cross_entity_je(postings)
        if leg_persisted?(postings)
          # An EXISTING leg edited on JE₁'s edit page (#4). Only touch it if the
          # admin can access JE₂ (scoped lookup) — otherwise leave it untouched, so
          # a single-side admin can never corrupt (or duplicate) the other book.
          next unless existing
          if all_postings_destroyed?(postings)
            existing.destroy! # sever of JE₁'s gift handled by the model callback
          else
            existing.entry_date = journal_entry.entry_date # keep JE₂ synced to JE₁
            existing.update!(postings_attributes: postings)
          end
        else
          # A brand-new leg added in this save. All-destroyed → ticked away, skip.
          next if all_postings_destroyed?(postings)
          JournalEntry.create!(
            entry_date: journal_entry.entry_date, # server-authoritative, synced to JE₁
            postings_attributes: postings
          )
        end
      end
      Current.skip_cross_entity_consistency = false
      verify_cross_entity_links!(journal_entry) # now that both sides are written
    end
    true
  rescue ActiveRecord::RecordInvalid => e
    # A LINKED entry failed (origin was valid) → surface its errors for the form.
    if journal_entry.errors.empty? && e.record && e.record != journal_entry
      e.record.errors.full_messages.each { |m| journal_entry.errors.add(:base, m) }
    end
    false
  ensure
    Current.skip_cross_entity_consistency = false
  end

  # After a coupled save, each link must bind exactly two mirrored bridge postings
  # (equal amount, opposite side, different JE + entity). Catches a bad/inconsistent
  # submit that the suppressed per-posting guard would otherwise have blocked.
  def verify_cross_entity_links!(journal_entry)
    link_ids = journal_entry.postings.filter_map { |p| p.cross_entity_link_id.presence }.uniq
    link_ids.each do |lid|
      ps = Posting.where(cross_entity_link_id: lid).includes(:account).to_a
      next if ps.empty? # leg was deleted (gift severed) — nothing to verify
      ok = ps.size == 2 &&
           ps[0].amount == ps[1].amount &&
           ps[0].entry_type != ps[1].entry_type &&
           ps[0].journal_entry_id != ps[1].journal_entry_id &&
           ps[0].account&.entity_code != ps[1].account&.entity_code
      next if ok
      journal_entry.errors.add(:base, I18n.t("postings.errors.cross_entity_link_invalid"))
      raise ActiveRecord::RecordInvalid, journal_entry
    end
  end

  # True when every posting of a linked entry is marked for destruction (or there
  # are none) — the leg was added then ticked away in the form. Handles both the
  # permitted-params shape (save) and the plain string-keyed hash (re-render #to_h).
  def all_postings_destroyed?(postings_attributes)
    list = postings_attributes.respond_to?(:values) ? postings_attributes.values : Array(postings_attributes)
    return true if list.blank?
    list.all? do |p|
      flag = p[:_destroy].nil? ? p["_destroy"] : p[:_destroy]
      ActiveModel::Type::Boolean.new.cast(flag)
    end
  end

  # True when a submitted leg carries a persisted posting id — i.e. it's an
  # existing JE₂ being edited, not a new one being created.
  def leg_persisted?(postings_attributes)
    posting_list(postings_attributes).any? { |p| (p[:id] || p["id"]).present? }
  end

  # The existing JE₂ a submitted leg refers to, via one of its posting ids —
  # SCOPED to what the admin can access (so a single-side admin can't update or
  # destroy the other entity's book). nil when new or inaccessible.
  def existing_cross_entity_je(postings_attributes)
    ids = posting_list(postings_attributes).filter_map { |p| p[:id] || p["id"] }
    return nil if ids.empty?
    accessible_postings.find_by(id: ids)&.journal_entry
  end

  def posting_list(postings_attributes)
    postings_attributes.respond_to?(:values) ? postings_attributes.values : Array(postings_attributes)
  end

  # COPY (#8): for each of `original`'s gift legs, mint a FRESH link_id and build
  # an unsaved JE₂′ (from the counterpart, copied fields, no ids/receipts). Returns
  # a `link_remap` (old→new for gifts; old→nil to STRIP any non-gift link, e.g. when
  # a counterpart JE₂ is copied standalone) and a `@cross_entity_rerender`-shaped
  # `rerender` so the pre-filled form draws the mirror band. Saving it (no posting
  # ids) creates a brand-new linked pair; the original is untouched.
  def build_cross_entity_copy(original)
    remap    = {}
    rerender = {}
    original.postings.each_with_index do |gift, idx|
      next unless gift.cross_entity_link_id.present? && gift.account&.personal?
      je2 = gift.cross_entity_counterpart&.journal_entry
      next unless je2
      old_link = gift.cross_entity_link_id
      new_link = SecureRandom.uuid
      remap[old_link] = new_link
      capital = je2.postings.detect { |p| p.cross_entity_link_id == old_link }
      linked  = JournalEntry.new
      je2.postings.each do |p|
        linked.postings.build(
          account_id: p.account_id, entry_type: p.entry_type, amount: p.amount,
          currency: p.currency, description: p.description, reference: p.reference,
          cross_entity_link_id: (p == capital ? new_link : nil)
        )
      end
      rerender[new_link] = {
        entry_index: "#{Time.now.to_i}#{idx}", link_id: new_link,
        amount: capital&.amount_display_formatted, linked: linked
      }
    end
    # Any remaining link (not a gift here → copying a counterpart) is stripped.
    original.postings.each do |p|
      remap[p.cross_entity_link_id] = nil if p.cross_entity_link_id.present? && !remap.key?(p.cross_entity_link_id)
    end
    { link_remap: remap, rerender: rerender }
  end

  # A copy of a cross-entity COUNTERPART (JE₂) should copy the whole transaction —
  # redirect to copy the ORIGIN (JE₁). Returns true when it redirected.
  def redirect_cross_entity_counterpart_to_copy(journal_entry)
    origin = journal_entry.cross_entity_counterpart_origin
    return false unless origin && accessible_journal_entries.exists?(origin.id)
    redirect_to duplicate_journal_entry_path(origin)
    true
  end

  # A cross-entity COUNTERPART (JE₂) is edited from the ONE surface — JE₁'s edit —
  # from EVERY entry point (JE edit AND the bank deposit/withdrawal edit, which a
  # ledger routes to when JE₂'s equity capital counts as a balance account).
  # Redirects and returns true when it handled the request; false to carry on.
  def redirect_cross_entity_counterpart_to_origin(journal_entry)
    origin = journal_entry.cross_entity_counterpart_origin
    return false unless origin
    if accessible_journal_entries.exists?(origin.id)
      redirect_to edit_journal_entry_path(origin)
    else
      # Holds JE₂'s entity but not JE₁'s → can't do the coupled edit.
      redirect_to journal_entry_path(journal_entry), alert: t("journal_entries.cross_entity_needs_both")
    end
    true
  end

  # For JE₁'s EDIT page (#4): rebuild the mirror-row band from the PERSISTED
  # counterpart JEs (not from params), keyed by the gift's link_id — same shape as
  # cross_entity_rerender_entries, so the form renders them identically. The
  # entry_index is JE₂'s id (numeric, stable, unique). Returns {} for a non-origin.
  def cross_entity_persisted_entries(journal_entry)
    return {} unless journal_entry.cross_entity_origin?
    journal_entry.postings.each_with_object({}) do |gift, acc|
      next unless gift.cross_entity_link_id.present? && gift.account&.personal?
      je2 = gift.cross_entity_counterpart&.journal_entry
      next unless je2
      capital = je2.postings.detect { |p| p.cross_entity_link_id == gift.cross_entity_link_id }
      acc[gift.cross_entity_link_id] = {
        entry_index: je2.id.to_s,
        link_id:     gift.cross_entity_link_id,
        amount:      capital&.amount_display_formatted, # 100.00, not the raw 100.0
        linked:      je2
      }
    end
  end

  def cross_entity_entries_params
    permitted = params.fetch(:journal_entry, {})
                      .permit(cross_entity_entries: [:entry_date, { postings_attributes: POSTING_PARAMS }])[:cross_entity_entries]
    return [] if permitted.blank?

    permitted.is_a?(Array) ? permitted : permitted.values
  end

  # For an error re-render: rebuilds each submitted linked entry as an UNSAVED
  # JournalEntry (from the permitted params, minus receipts — files don't survive
  # a re-render), keyed by its capital posting's cross_entity_link_id. The form
  # re-draws the mirror rows under the matching 601 gift so nothing is lost and the
  # params round-trip. Returns {} when there are none.
  def cross_entity_rerender_entries
    permitted = params.fetch(:journal_entry, {})
                      .permit(cross_entity_entries: [:entry_date, { postings_attributes: POSTING_PARAMS }])[:cross_entity_entries]
    return {} if permitted.blank?

    permitted.to_h.each_with_object({}) do |(entry_index, entry), acc|
      postings = entry["postings_attributes"]
      next if postings.blank?
      # A leg ticked away shouldn't reappear on an error re-render.
      next if all_postings_destroyed?(postings)
      # Strip id/receipts to BUILD unsaved display postings (postings_attributes
      # with an id would try to find a record inside a new JE → RecordNotFound),
      # then re-apply the ids so a resubmit still UPDATES the existing JE₂.
      clean   = postings.transform_values { |p| p.except("receipts_attributes", "id") }
      linked  = JournalEntry.new(postings_attributes: clean)
      postings.values.each_with_index do |p, i|
        linked.postings[i].id = p["id"] if p["id"].present? && linked.postings[i]
      end
      capital = linked.postings.detect { |p| p.cross_entity_link_id.present? }
      next unless capital

      acc[capital.cross_entity_link_id] = {
        entry_index: entry_index.to_s,
        link_id:     capital.cross_entity_link_id,
        amount:      clean.values.first&.dig("amount_display"),
        linked:      linked
      }
    end
  end
end
