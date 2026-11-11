# frozen_string_literal: true

class AddInstitutionalAlertSources < ActiveRecord::Migration[8.0]
  def up
    create_table :institutional_change_snapshots do |t|
      t.string :event_key, null: false, index: { unique: true }
      t.references :institutional_filer, null: false, foreign_key: true
      t.references :primary_filing, null: false, foreign_key: { to_table: :filings }
      t.date :period_of_report, null: false
      t.date :prior_period_of_report, null: false
      t.string :cusip, null: false
      t.string :put_call
      t.string :share_type, null: false
      t.string :name_of_issuer
      t.string :title_of_class
      t.string :change_type, null: false
      %i[shares_before shares_after shares_delta value_usd_before value_usd_after value_usd_delta].each { |field| t.decimal field }
      t.boolean :current_suspect, null: false, default: false
      t.boolean :prior_suspect, null: false, default: false
      t.boolean :values_complete, null: false
      t.bigint :current_report_ids, array: true, null: false
      t.bigint :prior_report_ids, array: true, null: false
      t.bigint :evidence_report_ids, array: true, null: false
      t.datetime :observed_at, null: false
      t.timestamps
    end
    add_check_constraint :institutional_change_snapshots, "event_key ~ '^[0-9a-f]{64}$' AND cusip ~ '^[0-9A-Z]{9}$' AND share_type IN ('SH', 'PRN') AND (put_call IS NULL OR put_call IN ('PUT', 'CALL')) AND change_type IN ('new', 'add', 'trim', 'exit')", name: "institutional_snapshot_identity"
    add_check_constraint :institutional_change_snapshots, "prior_period_of_report = date_trunc('quarter', period_of_report)::date - 1 AND cardinality(current_report_ids) > 0 AND cardinality(prior_report_ids) > 0 AND cardinality(evidence_report_ids) >= cardinality(current_report_ids) + cardinality(prior_report_ids)", name: "institutional_snapshot_context"
    add_reference :alert_deliveries, :institutional_change_snapshot, foreign_key: true
    remove_check_constraint :alert_deliveries, name: "alert_delivery_source"
    add_check_constraint :alert_deliveries, <<~SQL.squish, name: "alert_delivery_source"
      (event_type = 'new_filing' AND insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL)
      OR (event_type = 'insider_transaction' AND insider_transaction_id IS NOT NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL)
      OR (event_type = 'cluster' AND insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NOT NULL AND institutional_change_snapshot_id IS NULL)
      OR (event_type = '13f_change' AND insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NOT NULL)
    SQL
    remove_index :alert_deliveries, name: :index_alert_deliveries_on_alert_rule_id_and_filing_id
    add_index :alert_deliveries, [ :alert_rule_id, :filing_id ], unique: true,
      where: "insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL", name: :index_alert_deliveries_on_alert_rule_id_and_filing_id
    add_index :alert_deliveries, [ :alert_rule_id, :institutional_change_snapshot_id ], unique: true,
      where: "institutional_change_snapshot_id IS NOT NULL", name: :index_alert_deliveries_on_rule_and_institutional_change
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Review institutional alert history before removing its snapshots"
  end
end
