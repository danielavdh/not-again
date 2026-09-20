# frozen_string_literal: true

# Permanently deletes an orphaned entity and ALL its data once its retention
# period has passed. Deletes in FK-dependency order (no table has ON DELETE
# CASCADE), entirely via delete_all/update_all so nothing is loaded into Ruby.
#
# The entity's accounts, journal entries and postings are NOT foreign-keyed to
# the entity — they are code-partitioned — so a plain entity.destroy would leave
# them behind. This service removes them explicitly.
class EntityPurgeService
  Result = Struct.new(:code, :name, :counts, keyword_init: true)

  def initialize(entity)
    @entity = entity
  end

  def self.call(entity) = new(entity).call

  def call
    raise ArgumentError, "refusing to purge an entity that still has admins" unless @entity.orphaned?

    code    = @entity.code
    name    = @entity.name
    counts  = {}

    # Shrine's data blobs for every receipt scan, captured BEFORE the
    # transaction deletes the rows and deleted AFTER it commits. Deleting the
    # files first means a rollback leaves receipts pointing at nothing.
    scan_blobs  = Receipt.where(entity_id: @entity.id).where.not(scan_data: nil).pluck(:scan_data)
    report_ids  = nil

    ActiveRecord::Base.transaction do
      account_ids = Account.for_entity_codes([code]).pluck(:id)
      posting_ids = Posting.where(account_id: account_ids).pluck(:id)
      je_ids      = Posting.where(account_id: account_ids)
                                .distinct.pluck(:journal_entry_id)
      rg_ids      = ReportGroup.where(entity_id: @entity.id).pluck(:id)

      # 1. Receipts (reference entity + postings) — go first so postings are
      # free.
      counts[:receipts] = Receipt.where(entity_id: @entity.id).delete_all

      # 2. Postings on this entity's accounts.
      counts[:postings] = Posting.where(id: posting_ids).delete_all

      # Journal entries that are now empty. In normal data every entry is
      # single-entity, so all of je_ids become empty and are deleted. A
      # pathological cross-entity entry keeps its other postings and is left
      # intact — never delete another entity's data, and never dangle an FK.
      counts[:journal_entries] =
        JournalEntry.where(id: je_ids)
                         .where.not(id: Posting.select(:journal_entry_id))
                         .delete_all

      # Report structures (report_group_accounts reference accounts too). Ids
      # are captured before delete_all because they are needed after commit to
      # purge each report's tax-export backups: TaxExportStorage is partitioned
      # by report id, not by entity code, so it cannot be swept by code like
      # archives.
      report_ids = Report.where(report_group_id: rg_ids).pluck(:id)
      ReportGroupAccount.where(report_group_id: rg_ids).delete_all
      ReportGroupAccount.where(account_id: account_ids).delete_all
      counts[:reports]       = Report.where(id: report_ids).delete_all
      counts[:report_groups] = ReportGroup.where(id: rg_ids).delete_all

      # 5. Accounts — break the self-referential parent_id first, then delete.
      Account.where(id: account_ids).update_all(parent_id: nil)
      counts[:accounts] = Account.where(id: account_ids).delete_all

      # Any residual admin links (an orphan has none, but be safe) and the
      # membership timeline — an FK, and delete_all skips dependent: :destroy —
      # then the entity.
      AdminEntity.where(entity_id: @entity.id).delete_all
      EntityGroupMembership.where(entity_id: @entity.id).delete_all
      @entity.delete
    end

    # The transaction committed — now the object-storage cleanup, which cannot
    # be rolled back and so must come last.
    destroy_scan_files(scan_blobs)
    # archives/<code>/ is exactly this entity's own-scope books. A family
    # member's data also lives under the shared g<id>/ key, which is NOT
    # touched: it is the family's history and outlives one member.
    #
    # So a purged member's rows do remain inside those shared files — a
    # documented GDPR limitation, not an oversight.
    Archives::Storage.delete_scope(code)
    Filing::Storage.delete_all_for(code)
    report_ids.each { |id| TaxExportStorage.delete_report(id) }

    Result.new(code: code, name: name, counts: counts)
  end

  private

  # Deletes each captured receipt scan (and its derivatives) via Shrine's
  # backgrounding path — a throwaway Receipt just to carry the attacher.
  def destroy_scan_files(scan_blobs)
    scan_blobs.each do |data|
      attacher = Receipt.new(scan_data: data).scan_attacher
      attacher.destroy_background if attacher.file
    end
  end
end
