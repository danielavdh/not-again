# frozen_string_literal: true

# Operator-added languages — everything the shipped LANGUAGES array and the
# five help-doc files used to be, except sudo-owned and requiring no deploy.
#
# `code` collides with LANGUAGES (config/initializers/locale.rb) on purpose —
# it is the same namespace, just a second source of it. The model enforces
# they never overlap; see Language#code validation.
class CreateLanguages < ActiveRecord::Migration[8.1]
  def change
    create_table :languages do |t|
      t.string :code, limit: 2, null: false
      t.string :label, null: false
      t.boolean :rtl, null: false, default: false
      t.text :yml_content
      t.text :easy_manual_textile
      t.text :pro_manual_textile
      t.text :legal_textile
      t.text :terms_textile
      t.integer :status, null: false, default: 0
      t.references :released_by_admin, foreign_key: { to_table: :admins }
      t.datetime :released_at

      t.timestamps
    end

    add_index :languages, :code, unique: true
  end
end
