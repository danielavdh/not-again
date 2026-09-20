class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    # General-purpose from the start — one row per kind of installation-level
    # document, not just the compliance one this was built for. "There is
    # always stuff to upload."
    create_table :documents do |t|
      t.string :kind, null: false
      t.references :uploaded_by, foreign_key: { to_table: :admins, on_delete: :nullify }, null: true
      t.jsonb  :doc_data

      t.timestamps
    end

    # One document per kind, ever. Uploading again REPLACES it (see
    # DocumentsController) rather than accumulating a history — there is no
    # reason to keep an old EU declaration of conformity around once a new
    # one has been signed; the current one is the only one anybody wants.
    add_index :documents, :kind, unique: true
  end
end
