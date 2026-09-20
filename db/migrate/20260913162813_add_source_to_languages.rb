# frozen_string_literal: true

# Splits what Language rows are FOR — see the conversation this came out of.
# A system row is a toggle: code/label mirror LANGUAGES, content fields stay
# empty, the file on disk is the only copy, always current with whatever is
# deployed. A custom row is what it already was: sudo-authored, content
# lives in the database, goes through draft/release review.
#
# Seeded here, not in db/seeds.rb: these four rows have to exist the moment
# this migration runs, on every install, the same way the shipped
# LANGUAGES entries always have — not something a fresh db:seed run might
# be skipped or re-run separately from.
class AddSourceToLanguages < ActiveRecord::Migration[8.1]
  def up
    add_column :languages, :source, :integer, null: false, default: 1 # custom

    # Released — not draft — so a fresh install keeps exactly the four
    # languages it already had. Nothing about today's behaviour changes
    # just because this migration ran.
    execute <<~SQL
      INSERT INTO languages (code, label, source, status, created_at, updated_at)
      VALUES
        ('de', 'Deutsch', 0, 1, NOW(), NOW()),
        ('es', 'Español', 0, 1, NOW(), NOW()),
        ('nl', 'Nederlands', 0, 1, NOW(), NOW()),
        ('ar', 'العربية', 0, 1, NOW(), NOW())
    SQL
  end

  def down
    execute "DELETE FROM languages WHERE source = 0"
    remove_column :languages, :source
  end
end
