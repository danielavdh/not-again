# frozen_string_literal: true

# Lists journal entries whose postings span more than one consolidation GROUP;
# an ungrouped entity is its own group. Cross-entity entries WITHIN a family are
# legitimate — only cross-group ones break a family's standalone balance, and
# those must be split into linked per-family entries.
desc "Report journal entries whose postings span more than one consolidation group"
task cross_entity_journal_entries: :environment do
  # Group key per entity: grouped entities share "g<id>", ungrouped key on
  # their own code "e<code>". A JE crossing groups has > 1 distinct key.
  group_key = "COALESCE('g' || e.entity_group_id::text, 'e' || e.code)"
  sql = <<~SQL.squish
    SELECT p.journal_entry_id AS je_id,
           STRING_AGG(DISTINCT e.code, ',' ORDER BY e.code) AS entity_codes
    FROM postings p
    JOIN accounts a  ON a.id = p.account_id
    JOIN entities e  ON e.code = SUBSTRING(a.code, 2, 2)
    GROUP BY p.journal_entry_id
    HAVING COUNT(DISTINCT #{group_key}) > 1
    ORDER BY p.journal_entry_id
  SQL

  rows = ActiveRecord::Base.connection.select_all(sql)
  if rows.count.zero?
    puts "No cross-group journal entries. ✓"
    next
  end

  puts "#{rows.count} cross-group journal entr#{rows.count == 1 ? 'y' : 'ies'} (need splitting):"
  rows.each do |r|
    je = JournalEntry.find_by(id: r["je_id"])
    puts "  JE ##{r['je_id']}  entities=#{r['entity_codes']}  date=#{je&.entry_date}  memo=#{je&.memo.to_s.truncate(50)}"
  end
end
