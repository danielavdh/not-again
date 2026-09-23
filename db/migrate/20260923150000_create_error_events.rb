class CreateErrorEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :error_events do |t|
      t.string  :error_class,  null: false
      t.string  :source,       null: false
      t.date    :day,          null: false
      t.integer :occurrences,  null: false, default: 1
      t.string  :last_message
      t.string  :last_path
      t.string  :last_line
      t.datetime :last_seen_at, null: false
    end

    # One row per kind of error per day, incremented — a crash loop writes one
    # row, not thousands. The unique index IS the aggregation.
    add_index :error_events, [ :error_class, :source, :day ], unique: true
    add_index :error_events, :last_seen_at
  end
end
