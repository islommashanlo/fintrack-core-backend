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

ActiveRecord::Schema[8.0].define(version: 2026_11_11_030000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "alert_deliveries", force: :cascade do |t|
    t.bigint "alert_rule_id", null: false
    t.bigint "filing_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "delivered_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "frequency", default: "instant", null: false
    t.index ["alert_rule_id", "filing_id"], name: "index_alert_deliveries_on_alert_rule_id_and_filing_id", unique: true
    t.index ["alert_rule_id"], name: "index_alert_deliveries_on_alert_rule_id"
    t.index ["filing_id"], name: "index_alert_deliveries_on_filing_id"
    t.check_constraint "frequency::text = ANY (ARRAY['instant'::character varying::text, 'daily_digest'::character varying::text])", name: "alert_delivery_frequency"
  end

  create_table "alert_digest_batches", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.date "local_date", null: false
    t.string "time_zone", null: false
    t.string "status", default: "pending", null: false
    t.datetime "started_at"
    t.datetime "delivered_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["status", "created_at"], name: "index_alert_digest_batches_on_status_and_created_at"
    t.index ["user_id", "local_date"], name: "index_alert_digest_batches_on_user_id_and_local_date", unique: true
    t.index ["user_id"], name: "index_alert_digest_batches_on_user_id"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'sending'::character varying::text, 'sent'::character varying::text, 'failed'::character varying::text, 'canceled'::character varying::text])", name: "alert_digest_status"
  end

  create_table "alert_digest_items", force: :cascade do |t|
    t.bigint "alert_digest_batch_id", null: false
    t.bigint "alert_delivery_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["alert_delivery_id"], name: "index_alert_digest_items_on_alert_delivery_id", unique: true
    t.index ["alert_digest_batch_id"], name: "index_alert_digest_items_on_alert_digest_batch_id"
  end

  create_table "alert_event_states", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "alert_delivery_id", null: false
    t.datetime "read_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["alert_delivery_id"], name: "index_alert_event_states_on_alert_delivery_id"
    t.index ["user_id", "alert_delivery_id"], name: "index_alert_event_states_on_user_id_and_alert_delivery_id", unique: true
    t.index ["user_id", "read_at"], name: "index_alert_event_states_on_user_id_and_read_at"
    t.index ["user_id"], name: "index_alert_event_states_on_user_id"
  end

  create_table "alert_rule_settings", force: :cascade do |t|
    t.bigint "alert_rule_id", null: false
    t.string "frequency", default: "daily_digest", null: false
    t.jsonb "conditions", default: {}, null: false
    t.datetime "enabled_at"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["alert_rule_id"], name: "index_alert_rule_settings_on_alert_rule_id", unique: true
    t.index ["frequency", "archived_at"], name: "index_alert_rule_settings_on_frequency_and_archived_at"
    t.check_constraint "frequency::text = ANY (ARRAY['instant'::character varying::text, 'daily_digest'::character varying::text])", name: "alert_setting_frequency"
    t.check_constraint "jsonb_typeof(conditions) = 'object'::text", name: "alert_setting_conditions_object"
  end

  create_table "alert_rules", force: :cascade do |t|
    t.bigint "follow_id", null: false
    t.string "event_type", default: "new_filing", null: false
    t.string "channel", default: "email", null: false
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["follow_id", "event_type", "channel"], name: "index_alert_rules_on_follow_id_and_event_type_and_channel", unique: true
    t.index ["follow_id"], name: "index_alert_rules_on_follow_id"
  end

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
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'done'::character varying::text, 'no_index'::character varying::text, 'failed'::character varying::text])", name: "backfill_runs_status_check"
  end

  create_table "billing_customers", force: :cascade do |t|
    t.bigint "user_id"
    t.string "stripe_id", null: false
    t.boolean "livemode", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["stripe_id", "livemode"], name: "index_billing_customers_on_stripe_id_and_livemode", unique: true
    t.index ["user_id", "livemode"], name: "index_billing_customers_on_user_id_and_livemode", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["user_id"], name: "index_billing_customers_on_user_id"
  end

  create_table "billing_events", force: :cascade do |t|
    t.string "stripe_id", null: false
    t.string "event_type", null: false
    t.string "api_version", null: false
    t.boolean "livemode", null: false
    t.datetime "provider_created_at", null: false
    t.string "stripe_customer_id"
    t.string "stripe_subscription_id"
    t.string "payload_digest", null: false
    t.string "status", default: "pending", null: false
    t.string "reason"
    t.integer "attempts", default: 0, null: false
    t.datetime "verified_at", null: false
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["status", "created_at"], name: "index_billing_events_on_status_and_created_at"
    t.index ["stripe_customer_id", "livemode"], name: "index_billing_events_on_stripe_customer_id_and_livemode"
    t.index ["stripe_id", "livemode"], name: "index_billing_events_on_stripe_id_and_livemode", unique: true
    t.check_constraint "attempts >= 0", name: "billing_event_attempts"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'processed'::character varying, 'ignored'::character varying, 'failed'::character varying, 'needs_review'::character varying]::text[])", name: "billing_event_status"
  end

  create_table "cusip_security_mappings", force: :cascade do |t|
    t.string "cusip", null: false
    t.bigint "security_id"
    t.string "source", default: "openfigi", null: false
    t.integer "result_seq", null: false
    t.string "status", null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_checked_at", null: false
    t.string "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cusip", "source", "result_seq"], name: "index_cusip_mappings_on_cusip_source_sequence", unique: true
    t.index ["cusip", "source", "status"], name: "index_cusip_mappings_on_cusip_source_status"
    t.index ["security_id"], name: "index_cusip_security_mappings_on_security_id"
    t.check_constraint "result_seq >= 0", name: "cusip_security_mappings_result_seq_nonnegative"
    t.check_constraint "status::text = ANY (ARRAY['mapped'::character varying::text, 'unmapped'::character varying::text, 'ambiguous'::character varying::text, 'error'::character varying::text, 'stale'::character varying::text])", name: "cusip_security_mappings_status_check"
  end

  create_table "filers", force: :cascade do |t|
    t.string "cik", null: false
    t.string "name", null: false
    t.string "filer_type", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cik"], name: "index_filers_on_cik", unique: true
  end

  create_table "filing_explanations", force: :cascade do |t|
    t.bigint "filing_id", null: false
    t.string "source_digest", null: false
    t.string "prompt_version", null: false
    t.string "provider_key", null: false
    t.string "model", null: false
    t.string "generation_method", null: false
    t.text "body", null: false
    t.jsonb "coverage", default: {}, null: false
    t.datetime "generated_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["filing_id", "source_digest", "prompt_version", "provider_key"], name: "index_filing_explanations_on_source_and_provider", unique: true
    t.index ["filing_id"], name: "index_filing_explanations_on_filing_id"
    t.check_constraint "generation_method::text = ANY (ARRAY['template'::character varying, 'provider'::character varying]::text[])", name: "filing_explanation_method"
    t.check_constraint "jsonb_typeof(coverage) = 'object'::text", name: "filing_explanation_coverage"
    t.check_constraint "source_digest::text ~ '^[0-9a-f]{64}$'::text", name: "filing_explanation_digest"
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
    t.string "owner_ciks", default: [], null: false, array: true
    t.datetime "accepted_at"
    t.datetime "ingested_at"
    t.index ["accepted_at"], name: "index_filings_on_accepted_at"
    t.index ["accession_no"], name: "index_filings_on_accession_no", unique: true
    t.index ["filed_at"], name: "index_filings_on_filed_at"
    t.index ["form_type", "filed_on"], name: "index_filings_on_form_type_and_filed_on"
    t.index ["ingested_at"], name: "index_filings_on_ingested_at"
    t.index ["issuer_cik", "period_of_report"], name: "index_filings_on_issuer_cik_and_period_of_report"
    t.index ["owner_ciks"], name: "index_filings_on_owner_ciks", using: :gin
    t.index ["parse_status"], name: "index_filings_on_parse_status"
    t.check_constraint "parse_status::text = ANY (ARRAY['pending'::character varying::text, 'parsed'::character varying::text, 'failed'::character varying::text])", name: "filings_parse_status_check"
  end

  create_table "follows", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "target_type", null: false
    t.string "target_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "removed_at"
    t.datetime "followed_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["user_id", "removed_at"], name: "index_follows_on_user_id_and_removed_at"
    t.index ["user_id", "target_type", "target_key"], name: "index_follows_on_user_id_and_target_type_and_target_key", unique: true
    t.index ["user_id"], name: "index_follows_on_user_id"
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
    t.check_constraint "security_table::text = ANY (ARRAY['non_derivative'::character varying::text, 'derivative'::character varying::text])", name: "insider_transactions_security_table_check"
  end

  create_table "institutional_filers", force: :cascade do |t|
    t.string "cik", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cik"], name: "index_institutional_filers_on_cik", unique: true
  end

  create_table "institutional_holdings", force: :cascade do |t|
    t.bigint "institutional_report_id", null: false
    t.integer "row_seq", null: false
    t.string "cusip"
    t.string "name_of_issuer", null: false
    t.string "title_of_class", null: false
    t.decimal "value_reported", null: false
    t.string "value_unit", null: false
    t.decimal "value_usd"
    t.decimal "shares", null: false
    t.string "share_type", null: false
    t.string "put_call"
    t.string "investment_discretion"
    t.string "other_manager"
    t.decimal "voting_sole"
    t.decimal "voting_shared"
    t.decimal "voting_none"
    t.string "figi"
    t.boolean "suspect", default: false, null: false
    t.string "suspect_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cusip"], name: "index_institutional_holdings_on_cusip"
    t.index ["institutional_report_id", "row_seq"], name: "index_13f_holdings_on_report_and_row", unique: true
    t.check_constraint "row_seq > 0", name: "institutional_holdings_row_sequence_positive"
  end

  create_table "institutional_report_managers", force: :cascade do |t|
    t.bigint "institutional_report_id", null: false
    t.integer "sequence_no", null: false
    t.string "cik"
    t.string "name"
    t.string "form13f_file_number"
    t.string "crd_number"
    t.string "sec_file_number"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["institutional_report_id", "sequence_no"], name: "index_13f_report_managers_on_report_and_sequence", unique: true
    t.check_constraint "sequence_no > 0", name: "institutional_report_managers_sequence_positive"
  end

  create_table "institutional_reports", force: :cascade do |t|
    t.bigint "filing_id", null: false
    t.bigint "institutional_filer_id", null: false
    t.date "period_of_report", null: false
    t.datetime "filed_at"
    t.string "submission_type", null: false
    t.string "report_type", null: false
    t.string "amendment_type"
    t.integer "amendment_number"
    t.integer "other_included_managers_count"
    t.integer "table_entry_total"
    t.decimal "table_value_total"
    t.string "cover_value_unit"
    t.string "cover_raw_path"
    t.string "information_raw_path"
    t.string "status", default: "pending", null: false
    t.boolean "suspect", default: false, null: false
    t.string "suspect_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["filing_id"], name: "index_institutional_reports_on_filing_id", unique: true
    t.index ["institutional_filer_id", "filed_at"], name: "index_institutional_reports_on_filer_and_filed_at"
    t.index ["institutional_filer_id", "period_of_report"], name: "index_institutional_reports_on_filer_and_period"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'parsed'::character varying::text, 'failed'::character varying::text, 'skipped'::character varying::text])", name: "institutional_reports_status_check"
  end

  create_table "notification_preferences", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "time_zone"
    t.boolean "email_enabled", default: false, null: false
    t.datetime "email_enabled_at"
    t.integer "unsubscribe_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_notification_preferences_on_user_id", unique: true
    t.check_constraint "unsubscribe_version >= 0", name: "notification_unsubscribe_version"
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

  create_table "position_diffs", force: :cascade do |t|
    t.bigint "institutional_filer_id", null: false
    t.bigint "institutional_report_id", null: false
    t.bigint "prior_institutional_report_id"
    t.date "period_of_report", null: false
    t.date "prior_period_of_report"
    t.string "cusip", null: false
    t.string "put_call", default: "", null: false
    t.string "share_type", null: false
    t.string "change_type", null: false
    t.decimal "shares_before"
    t.decimal "shares_after"
    t.decimal "shares_delta", null: false
    t.decimal "value_usd_before"
    t.decimal "value_usd_after"
    t.decimal "value_usd_delta"
    t.string "name_of_issuer"
    t.string "title_of_class"
    t.boolean "current_suspect", default: false, null: false
    t.boolean "prior_suspect", default: false, null: false
    t.datetime "calculated_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["institutional_filer_id", "period_of_report", "change_type"], name: "index_position_diffs_on_filer_period_change"
    t.index ["institutional_filer_id", "period_of_report", "cusip", "put_call", "share_type"], name: "index_position_diffs_on_natural_key", unique: true
    t.check_constraint "change_type::text = ANY (ARRAY['new'::character varying::text, 'exit'::character varying::text, 'add'::character varying::text, 'trim'::character varying::text])", name: "position_diffs_change_type_check"
    t.check_constraint "shares_delta <> 0::numeric", name: "position_diffs_nonzero_share_delta"
  end

  create_table "saved_screens", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", limit: 100, null: false
    t.string "entity", null: false
    t.jsonb "filters", default: [], null: false
    t.string "sort", default: "name", null: false
    t.integer "window_days"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "user_id, lower((name)::text)", name: "index_saved_screens_on_user_and_name", unique: true
    t.index ["user_id", "entity", "created_at", "id"], name: "idx_on_user_id_entity_created_at_id_47390d35ff"
    t.index ["user_id"], name: "index_saved_screens_on_user_id"
    t.check_constraint "char_length(btrim(name::text)) >= 1 AND char_length(btrim(name::text)) <= 100", name: "saved_screen_name"
    t.check_constraint "entity::text = 'funds'::text AND window_days IS NULL OR (entity::text = ANY (ARRAY['companies'::character varying, 'insiders'::character varying]::text[])) AND window_days IS NOT NULL AND (window_days = ANY (ARRAY[30, 90, 365]))", name: "saved_screen_window"
    t.check_constraint "entity::text = ANY (ARRAY['companies'::character varying, 'funds'::character varying, 'insiders'::character varying]::text[])", name: "saved_screen_entity"
    t.check_constraint "jsonb_typeof(filters) = 'array'::text", name: "saved_screen_filters"
  end

  create_table "securities", force: :cascade do |t|
    t.string "figi", null: false
    t.string "ticker"
    t.string "name"
    t.string "security_type"
    t.string "market_sector"
    t.string "exchange_code"
    t.string "share_class_figi"
    t.string "composite_figi"
    t.string "source", default: "openfigi", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["figi"], name: "index_securities_on_figi", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "billing_customer_id", null: false
    t.bigint "billing_event_id", null: false
    t.string "stripe_id", null: false
    t.boolean "livemode", null: false
    t.string "status", null: false
    t.string "price_id"
    t.string "sync_status", default: "verified", null: false
    t.datetime "current_period_start"
    t.datetime "current_period_end"
    t.datetime "trial_end"
    t.datetime "cancel_at"
    t.boolean "cancel_at_period_end", default: false, null: false
    t.boolean "collection_paused", default: false, null: false
    t.datetime "verified_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["billing_customer_id"], name: "index_subscriptions_on_billing_customer_id"
    t.index ["billing_event_id"], name: "index_subscriptions_on_billing_event_id"
    t.index ["status", "sync_status", "current_period_end"], name: "index_subscriptions_on_entitlement"
    t.index ["stripe_id", "livemode"], name: "index_subscriptions_on_stripe_id_and_livemode", unique: true
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'trialing'::character varying, 'past_due'::character varying, 'canceled'::character varying, 'unpaid'::character varying, 'paused'::character varying, 'incomplete'::character varying, 'incomplete_expired'::character varying]::text[])", name: "subscription_status"
    t.check_constraint "sync_status::text = ANY (ARRAY['verified'::character varying, 'needs_review'::character varying]::text[])", name: "subscription_sync_status"
  end

  create_table "user_preferences", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "theme", default: "system", null: false
    t.string "dashboard_layout", default: "split", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_user_preferences_on_user_id", unique: true
    t.check_constraint "dashboard_layout::text = ANY (ARRAY['split'::character varying, 'focus'::character varying, 'columns'::character varying]::text[])", name: "user_preference_dashboard_layout"
    t.check_constraint "theme::text = ANY (ARRAY['system'::character varying, 'light'::character varying, 'dark'::character varying]::text[])", name: "user_preference_theme"
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "alert_deliveries", "alert_rules"
  add_foreign_key "alert_deliveries", "filings"
  add_foreign_key "alert_digest_batches", "users"
  add_foreign_key "alert_digest_items", "alert_deliveries"
  add_foreign_key "alert_digest_items", "alert_digest_batches"
  add_foreign_key "alert_event_states", "alert_deliveries"
  add_foreign_key "alert_event_states", "users"
  add_foreign_key "alert_rule_settings", "alert_rules"
  add_foreign_key "alert_rules", "follows"
  add_foreign_key "billing_customers", "users", on_delete: :nullify
  add_foreign_key "cusip_security_mappings", "securities"
  add_foreign_key "filing_explanations", "filings"
  add_foreign_key "follows", "users"
  add_foreign_key "insider_transactions", "filings"
  add_foreign_key "institutional_holdings", "institutional_reports"
  add_foreign_key "institutional_report_managers", "institutional_reports"
  add_foreign_key "institutional_reports", "filings"
  add_foreign_key "institutional_reports", "institutional_filers"
  add_foreign_key "notification_preferences", "users"
  add_foreign_key "position_diffs", "institutional_filers"
  add_foreign_key "position_diffs", "institutional_reports"
  add_foreign_key "position_diffs", "institutional_reports", column: "prior_institutional_report_id"
  add_foreign_key "saved_screens", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "subscriptions", "billing_customers"
  add_foreign_key "subscriptions", "billing_events"
  add_foreign_key "user_preferences", "users"
end
