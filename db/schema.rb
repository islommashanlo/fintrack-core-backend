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

ActiveRecord::Schema[8.0].define(version: 2026_10_02_170005) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "backfill_runs", force: :cascade do |t|
    t.date "day", null: false
    t.string "status", default: "pending", null: false
    t.integer "filings_found", default: 0, null: false
    t.integer "filings_new", default: 0, null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day"], name: "index_backfill_runs_on_day", unique: true
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'running'::character varying, 'done'::character varying, 'no_index'::character varying, 'failed'::character varying]::text[])", name: "backfill_runs_status_check"
  end

  create_table "filers", force: :cascade do |t|
    t.string "cik", null: false
    t.string "name", null: false
    t.string "filer_type", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cik"], name: "index_filers_on_cik", unique: true
  end

  create_table "filings", force: :cascade do |t|
    t.string "accession_no", null: false
    t.string "cik", null: false
    t.string "form_type", null: false
    t.date "filed_on"
    t.datetime "filed_at"
    t.date "period_of_report"
    t.string "raw_path"
    t.string "parse_status", default: "pending", null: false
    t.datetime "parsed_at"
    t.string "source"
    t.string "issuer_cik"
    t.string "issuer_name"
    t.string "issuer_ticker"
    t.boolean "aff10b5_one"
    t.jsonb "footnotes", default: {}, null: false
    t.date "date_of_original_submission"
    t.string "amends_accession_no"
    t.string "superseded_by_accession_no"
    t.string "unmatched_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["accession_no"], name: "index_filings_on_accession_no", unique: true
    t.index ["filed_at"], name: "index_filings_on_filed_at"
    t.index ["form_type", "filed_on"], name: "index_filings_on_form_type_and_filed_on"
    t.index ["issuer_cik", "period_of_report"], name: "index_filings_on_issuer_cik_and_period_of_report"
    t.index ["parse_status"], name: "index_filings_on_parse_status"
    t.check_constraint "parse_status::text = ANY (ARRAY['pending'::character varying, 'parsed'::character varying, 'failed'::character varying]::text[])", name: "filings_parse_status_check"
  end

  create_table "insider_transactions", force: :cascade do |t|
    t.bigint "filing_id", null: false
    t.string "accession_no", null: false
    t.string "insider_cik", null: false
    t.string "insider_name"
    t.integer "owner_seq", null: false
    t.string "issuer_cik", null: false
    t.string "issuer_ticker"
    t.string "security_table", null: false
    t.integer "txn_seq", null: false
    t.string "security_title"
    t.date "transaction_date"
    t.date "deemed_execution_date"
    t.string "transaction_code"
    t.string "transaction_form_type"
    t.boolean "equity_swap_involved"
    t.string "transaction_timeliness"
    t.decimal "shares"
    t.decimal "price"
    t.string "acquired_disposed"
    t.decimal "shares_owned_following"
    t.string "direct_or_indirect"
    t.string "nature_of_ownership"
    t.decimal "conversion_or_exercise_price"
    t.date "exercise_date"
    t.date "expiration_date"
    t.string "underlying_security_title"
    t.decimal "underlying_security_shares"
    t.boolean "is_director", default: false, null: false
    t.boolean "is_officer", default: false, null: false
    t.boolean "is_ten_percent_owner", default: false, null: false
    t.boolean "is_other", default: false, null: false
    t.string "officer_title"
    t.boolean "price_suspect", default: false, null: false
    t.string "price_suspect_reason"
    t.string "footnote_ids", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["accession_no", "insider_cik", "security_table", "txn_seq"], name: "index_insider_transactions_on_natural_key", unique: true
    t.index ["filing_id"], name: "index_insider_transactions_on_filing_id"
    t.index ["insider_cik", "transaction_date"], name: "index_insider_transactions_on_insider_cik_and_transaction_date"
    t.index ["issuer_cik", "transaction_date"], name: "index_insider_transactions_on_issuer_cik_and_transaction_date"
    t.index ["transaction_code"], name: "index_insider_transactions_on_transaction_code"
    t.check_constraint "security_table::text = ANY (ARRAY['non_derivative'::character varying, 'derivative'::character varying]::text[])", name: "insider_transactions_security_table_check"
  end

  create_table "parse_failures", force: :cascade do |t|
    t.string "accession_no", null: false
    t.text "error", null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "last_failed_at"
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["accession_no"], name: "index_parse_failures_on_accession_no", unique: true
  end

  add_foreign_key "insider_transactions", "filings"
end
