# frozen_string_literal: true

# The original index (CreateLanguages) enforced uniqueness on `code` alone —
# written before source existed, so it blocks the whole override feature at
# the database level even after the model-level validation was rescoped.
# Same code, different source, is the point; only same code AND same
# source should collide.
class ScopeLanguageCodeUniquenessToSource < ActiveRecord::Migration[8.1]
  def change
    remove_index :languages, :code
    add_index :languages, [ :code, :source ], unique: true
  end
end
