# frozen_string_literal: true

class CreateSecurityMappingsAndPositionDiffs < ActiveRecord::Migration[8.0]
  def change
    create_table :securities do |t|
      t.string :figi, null: false
      t.string :ticker
      t.string :name
      t.string :security_type
      t.string :market_sector
      t.string :exchange_code
      t.string :share_class_figi
      t.string :composite_figi
      t.string :source, null: false, default: "openfigi"

      t.timestamps
    end

    add_index :securities, :figi, unique: true

    create_table :cusip_security_mappings do |t|
      t.string :cusip, null: false
      t.references :security, foreign_key: true
      t.string :source, null: false, default: "openfigi"
      t.integer :result_seq, null: false
      t.string :status, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_checked_at, null: false
      t.string :error

      t.timestamps
    end

    add_index :cusip_security_mappings, %i[cusip source result_seq], unique: true,
              name: "index_cusip_mappings_on_cusip_source_sequence"
    add_index :cusip_security_mappings, %i[cusip source status],
              name: "index_cusip_mappings_on_cusip_source_status"
    add_check_constraint :cusip_security_mappings, "result_seq >= 0",
                         name: "cusip_security_mappings_result_seq_nonnegative"
    add_check_constraint :cusip_security_mappings,
                         "status IN ('mapped', 'unmapped', 'ambiguous', 'error', 'stale')",
                         name: "cusip_security_mappings_status_check"

    create_table :position_diffs do |t|
      t.references :institutional_filer, null: false, foreign_key: true, index: false
      t.references :institutional_report, null: false, foreign_key: true, index: false
      t.references :prior_institutional_report, foreign_key: { to_table: :institutional_reports }, index: false
      t.date :period_of_report, null: false
      t.date :prior_period_of_report
      t.string :cusip, null: false
      t.string :put_call, null: false, default: ""
      t.string :share_type, null: false
      t.string :change_type, null: false
      t.decimal :shares_before
      t.decimal :shares_after
      t.decimal :shares_delta, null: false
      t.decimal :value_usd_before
      t.decimal :value_usd_after
      t.decimal :value_usd_delta
      t.string :name_of_issuer
      t.string :title_of_class
      t.boolean :current_suspect, null: false, default: false
      t.boolean :prior_suspect, null: false, default: false
      t.datetime :calculated_at, null: false

      t.timestamps
    end

    add_index :position_diffs,
              %i[institutional_filer_id period_of_report cusip put_call share_type],
              unique: true, name: "index_position_diffs_on_natural_key"
    add_index :position_diffs, %i[institutional_filer_id period_of_report change_type],
              name: "index_position_diffs_on_filer_period_change"
    add_check_constraint :position_diffs, "change_type IN ('new', 'exit', 'add', 'trim')",
                         name: "position_diffs_change_type_check"
    add_check_constraint :position_diffs, "shares_delta <> 0",
                         name: "position_diffs_nonzero_share_delta"
  end
end
