class AddVat < ActiveRecord::Migration[8.1]
  def change
    # Boxes that are totals of others: HMRC's box 6 includes box 8, box 7 box 9,
    # box 3 boxes 1 and 2. A fact about the FORM, so it is declared once on the
    # box rather than on every code that feeds it.
    add_column :tax_categories, :includes, :string, array: true, default: [], null: false

    # Catalogue data, versioned by DATE because rates change mid-year
    # (DE 19→16 for H2 2020).
    create_table :tax_codes do |t|
      t.string  :country_code, limit: 2, null: false
      t.string  :scheme,                 null: false
      t.string  :key,                    null: false
      t.string  :label
      # Basis points: 1900 is 19%. Never a float.
      t.integer :rate_bps,               null: false
      t.date    :valid_from,             null: false
      t.date    :valid_to
      # Which control account the leg goes to, and which side.
      t.string  :direction,              null: false
      # One code, two legs netting to zero.
      t.boolean :reverse_charge, null: false, default: false
      # A rate cannot say which box: a zero-rated supply and an export are both
      # 0% and belong on different lines.
      t.string  :net_category_key
      t.string  :tax_category_key
      # Reverse charge's two legs go in two boxes — the UK puts the output half
      # in box 1 and the input in box 4. tax_category_key is the code's own
      # direction; this is the opposite leg.
      t.string  :reverse_tax_category_key
      # What a DATEV import expects.
      t.string  :datev_bu
      t.integer :position, null: false, default: 0
      t.timestamps

      # One row per key per validity window.
      t.index %i[country_code scheme key valid_from], unique: true, name: "index_tax_codes_lookup"
      t.index %i[scheme valid_from valid_to]
    end

    # On the NET posting.
    add_reference :postings, :tax_code, foreign_key: true, null: true
    # On the DERIVED leg. Never permitted from a form, so one cannot be typed.
    add_column :postings, :tax_for_posting_id, :bigint, null: true
    add_foreign_key :postings, :postings, column: :tax_for_posting_id, on_delete: :cascade
    add_index :postings, :tax_for_posting_id

    # With the existing tax_scheme column: gb_vat + input is the entity's UK
    # input-VAT account. Two authorities means two pairs.
    add_column :accounts, :vat_role, :integer, null: true
    add_index  :accounts, %i[tax_scheme vat_role]
    # Prefilled on a new row here; the posting's own tax_code_id is what counts.
    add_reference :accounts, :default_tax_code, foreign_key: { to_table: :tax_codes }, null: true
  end
end
