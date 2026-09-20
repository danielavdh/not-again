# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_20_094500) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gist"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_stat_statements"

  create_table "accounts", force: :cascade do |t|
    t.integer "account_type", null: false
    t.boolean "active", default: true, null: false
    t.string "code", limit: 6, null: false
    t.datetime "created_at", null: false
    t.string "currency", limit: 3
    t.integer "deduction_percentage"
    t.text "description"
    t.boolean "locked", default: false, null: false
    t.string "name", null: false
    t.bigint "parent_id"
    t.string "tax_category_key"
    t.integer "tax_position"
    t.string "tax_scheme"
    t.datetime "updated_at", null: false
    t.index ["account_type"], name: "index_accounts_on_account_type"
    t.index ["active"], name: "index_accounts_on_active"
    t.index ["code"], name: "index_accounts_on_code", unique: true
    t.index ["currency"], name: "index_accounts_on_currency"
    t.index ["parent_id"], name: "index_accounts_on_parent_id"
    t.index ["tax_scheme", "tax_category_key"], name: "index_accounts_on_tax_tag"
  end

  create_table "admin_entities", force: :cascade do |t|
    t.integer "access_level", default: 0, null: false
    t.bigint "admin_id", null: false
    t.datetime "created_at", null: false
    t.bigint "entity_id", null: false
    t.datetime "updated_at", null: false
    t.index ["access_level"], name: "index_admin_entities_on_access_level"
    t.index ["admin_id", "entity_id"], name: "index_admin_entities_on_admin_id_and_entity_id", unique: true
    t.index ["admin_id"], name: "index_admin_entities_on_admin_id"
    t.index ["entity_id"], name: "index_admin_entities_on_entity_id"
  end

  create_table "admins", force: :cascade do |t|
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.boolean "demo", default: false, null: false
    t.string "email_address"
    t.string "entity_code", limit: 2
    t.datetime "last_seen"
    t.boolean "otp_enabled", default: false, null: false
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.string "preferred_currency", limit: 3
    t.string "preferred_number_format"
    t.boolean "show_journal_entries", default: false, null: false
    t.boolean "sudo", default: false, null: false
    t.datetime "terms_agreed_at"
    t.string "terms_agreed_version"
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.datetime "verified_at"
    t.index ["demo"], name: "index_admins_on_demo_true", where: "demo"
    t.index ["email_address"], name: "index_admins_on_email_address", unique: true
    t.index ["username"], name: "index_admins_on_username", unique: true
  end

  create_table "currencies", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", limit: 3, null: false
    t.datetime "created_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.integer "minor_unit", default: 2, null: false
    t.integer "position", default: 0, null: false
    t.string "symbol", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_currencies_on_code", unique: true
    t.index ["position"], name: "index_currencies_on_position"
  end

  create_table "documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "doc_data"
    t.string "kind", null: false
    t.datetime "updated_at", null: false
    t.bigint "uploaded_by_id"
    t.index ["kind"], name: "index_documents_on_kind", unique: true
    t.index ["uploaded_by_id"], name: "index_documents_on_uploaded_by_id"
  end

  create_table "entities", force: :cascade do |t|
    t.string "accountant_export"
    t.boolean "active", default: true, null: false
    t.string "code", limit: 2, null: false
    t.datetime "created_at", null: false
    t.date "deletion_due_on"
    t.bigint "entity_group_id"
    t.string "name", null: false
    t.datetime "orphaned_at"
    t.string "tax_schemes", default: [], array: true
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_entities_on_active"
    t.index ["code"], name: "index_entities_on_code", unique: true
    t.index ["entity_group_id"], name: "index_entities_on_entity_group_id"
    t.index ["orphaned_at"], name: "index_entities_on_orphaned_at", where: "(orphaned_at IS NOT NULL)"
  end

  create_table "entity_group_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "ends_on"
    t.bigint "entity_group_id"
    t.bigint "entity_id", null: false
    t.date "starts_on", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_group_id", "starts_on"], name: "index_egm_on_group_and_start"
    t.index ["entity_group_id"], name: "index_entity_group_memberships_on_entity_group_id"
    t.index ["entity_id", "starts_on"], name: "index_egm_on_entity_and_start"
    t.index ["entity_id"], name: "index_entity_group_memberships_on_entity_id"
    t.index ["entity_id"], name: "index_one_open_membership_per_entity", unique: true, where: "(ends_on IS NULL)"
  end

  create_table "entity_groups", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "exchange_rates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "effective_date", null: false
    t.bigint "entered_by_id"
    t.bigint "entity_id"
    t.string "from_currency", limit: 3, null: false
    t.text "note"
    t.decimal "rate", precision: 18, scale: 8, null: false
    t.string "source", default: "manual"
    t.string "to_currency", limit: 3, null: false
    t.datetime "updated_at", null: false
    t.date "valid_from", null: false
    t.date "valid_to", null: false
    t.index ["effective_date"], name: "index_exchange_rates_on_effective_date"
    t.index ["entered_by_id"], name: "index_exchange_rates_on_entered_by_id"
    t.index ["entity_id"], name: "index_exchange_rates_on_entity_id"
    t.index ["from_currency", "to_currency", "valid_from", "source", "entity_id"], name: "idx_exchange_rates_unique", unique: true, nulls_not_distinct: true
    t.check_constraint "valid_to >= valid_from", name: "exchange_rates_span_ordered"
    t.exclusion_constraint "from_currency WITH =, to_currency WITH =, source WITH =, COALESCE(entity_id, (0)::bigint) WITH =, daterange(valid_from, valid_to, '[]'::text) WITH &&", using: :gist, name: "exchange_rates_no_overlap"
  end

  create_table "journal_entries", force: :cascade do |t|
    t.boolean "closing_entry", default: false, null: false
    t.datetime "created_at", null: false
    t.date "entry_date", null: false
    t.string "journal_reference"
    t.string "memo"
    t.date "period_end"
    t.date "period_start"
    t.boolean "posted", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["entry_date"], name: "index_journal_entries_on_entry_date"
    t.index ["journal_reference"], name: "index_journal_entries_on_journal_reference"
    t.index ["posted", "entry_date"], name: "index_journal_entries_on_posted_and_entry_date"
    t.index ["posted"], name: "index_journal_entries_on_posted"
  end

  create_table "languages", force: :cascade do |t|
    t.string "code", limit: 2, null: false
    t.datetime "created_at", null: false
    t.text "easy_manual_textile"
    t.string "label", null: false
    t.text "legal_textile"
    t.text "pro_manual_textile"
    t.datetime "released_at"
    t.bigint "released_by_admin_id"
    t.boolean "reviewed", default: false, null: false
    t.boolean "rtl", default: false, null: false
    t.integer "source", default: 1, null: false
    t.integer "status", default: 0, null: false
    t.text "terms_textile"
    t.datetime "updated_at", null: false
    t.text "yml_content"
    t.index ["code", "source"], name: "index_languages_on_code_and_source", unique: true
    t.index ["released_by_admin_id"], name: "index_languages_on_released_by_admin_id"
  end

  create_table "postings", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "amount", null: false
    t.datetime "created_at", null: false
    t.uuid "cross_entity_link_id"
    t.string "currency", limit: 3
    t.uuid "deduction_pair_id"
    t.integer "deduction_percentage"
    t.string "description"
    t.integer "entry_type", null: false
    t.bigint "journal_entry_id", null: false
    t.string "reference"
    t.datetime "updated_at", null: false
    t.index ["account_id", "journal_entry_id"], name: "index_postings_on_account_id_and_journal_entry_id"
    t.index ["account_id"], name: "index_postings_on_account_id"
    t.index ["cross_entity_link_id"], name: "index_postings_on_cross_entity_link_id"
    t.index ["currency"], name: "index_postings_on_currency"
    t.index ["deduction_pair_id"], name: "index_postings_on_deduction_pair_id"
    t.index ["description"], name: "index_postings_on_description"
    t.index ["entry_type"], name: "index_postings_on_entry_type"
    t.index ["journal_entry_id"], name: "index_postings_on_journal_entry_id"
    t.index ["reference"], name: "index_postings_on_reference"
  end

  create_table "receipts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "entity_id"
    t.bigint "posting_id"
    t.date "receipt_date", null: false
    t.jsonb "scan_data"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "uploaded_by_id"
    t.index ["entity_id", "receipt_date"], name: "index_receipts_on_entity_id_and_receipt_date"
    t.index ["entity_id"], name: "index_receipts_on_entity_id"
    t.index ["posting_id"], name: "index_receipts_on_posting_id"
    t.index ["uploaded_by_id"], name: "index_receipts_on_uploaded_by_id"
  end

  create_table "report_group_accounts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.integer "position"
    t.bigint "report_group_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_report_group_accounts_on_account_id"
    t.index ["report_group_id", "account_id"], name: "idx_report_group_accounts_unique", unique: true
    t.index ["report_group_id", "position"], name: "idx_report_group_accounts_position"
    t.index ["report_group_id"], name: "index_report_group_accounts_on_report_group_id"
  end

  create_table "report_groups", force: :cascade do |t|
    t.string "business_id"
    t.datetime "created_at", null: false
    t.string "description"
    t.bigint "entity_id"
    t.boolean "is_template", default: false, null: false
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.integer "position"
    t.string "tax_scheme"
    t.bigint "taxpayer_id"
    t.string "template_key"
    t.datetime "updated_at", null: false
    t.index ["entity_id", "position"], name: "index_report_groups_on_entity_id_and_position"
    t.index ["entity_id", "tax_scheme"], name: "index_report_groups_on_entity_and_tax_scheme", unique: true, where: "(tax_scheme IS NOT NULL)"
    t.index ["entity_id"], name: "index_report_groups_on_entity_id"
    t.index ["is_template"], name: "index_report_groups_on_is_template"
    t.index ["taxpayer_id"], name: "index_report_groups_on_taxpayer_id"
    t.index ["template_key"], name: "index_report_groups_on_template_key", unique: true
  end

  create_table "reports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "end_date", null: false
    t.string "name", null: false
    t.bigint "report_group_id", null: false
    t.date "start_date", null: false
    t.datetime "updated_at", null: false
    t.index ["report_group_id"], name: "index_reports_on_report_group_id"
    t.index ["start_date", "end_date"], name: "index_reports_on_start_date_and_end_date"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "admin_id"
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["admin_id"], name: "index_sessions_on_admin_id"
  end

  create_table "sign_in_events", force: :cascade do |t|
    t.bigint "admin_id"
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.integer "outcome", null: false
    t.string "user_agent"
    t.string "username_attempted", null: false
    t.index ["admin_id"], name: "index_sign_in_events_on_admin_id"
    t.index ["created_at"], name: "index_sign_in_events_on_created_at"
    t.index ["outcome", "created_at"], name: "index_sign_in_events_on_outcome_and_created_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "tax_categories", force: :cascade do |t|
    t.string "api_field"
    t.string "api_section"
    t.string "country_code", limit: 2, null: false
    t.datetime "created_at", null: false
    t.string "export_column"
    t.string "key", null: false
    t.string "keywords", default: [], array: true
    t.string "label"
    t.string "notes"
    t.integer "position", default: 0, null: false
    t.string "scheme", null: false
    t.string "section"
    t.integer "tax_year", null: false
    t.datetime "updated_at", null: false
    t.index ["country_code", "scheme", "tax_year", "key"], name: "index_tax_categories_lookup", unique: true
    t.index ["country_code", "scheme", "tax_year"], name: "index_tax_categories_on_country_code_and_scheme_and_tax_year"
  end

  create_table "taxpayers", force: :cascade do |t|
    t.text "access_token"
    t.bigint "admin_id"
    t.string "authority", null: false
    t.datetime "created_at", null: false
    t.jsonb "identifiers", default: {}, null: false
    t.string "label"
    t.text "refresh_token"
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.index ["admin_id", "authority"], name: "index_taxpayers_on_admin_id_and_authority"
    t.index ["admin_id"], name: "index_taxpayers_on_admin_id"
  end

  add_foreign_key "accounts", "accounts", column: "parent_id"
  add_foreign_key "admin_entities", "admins"
  add_foreign_key "admin_entities", "entities"
  add_foreign_key "documents", "admins", column: "uploaded_by_id", on_delete: :nullify
  add_foreign_key "entities", "entity_groups", on_delete: :nullify
  add_foreign_key "entity_group_memberships", "entities"
  add_foreign_key "exchange_rates", "admins", column: "entered_by_id", on_delete: :nullify
  add_foreign_key "exchange_rates", "entities"
  add_foreign_key "languages", "admins", column: "released_by_admin_id"
  add_foreign_key "postings", "accounts"
  add_foreign_key "postings", "journal_entries"
  add_foreign_key "receipts", "admins", column: "uploaded_by_id"
  add_foreign_key "receipts", "entities"
  add_foreign_key "receipts", "postings"
  add_foreign_key "report_group_accounts", "accounts"
  add_foreign_key "report_group_accounts", "report_groups"
  add_foreign_key "report_groups", "entities"
  add_foreign_key "report_groups", "taxpayers"
  add_foreign_key "reports", "report_groups"
  add_foreign_key "sessions", "admins"
  add_foreign_key "sign_in_events", "admins", on_delete: :nullify
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "taxpayers", "admins"
end
