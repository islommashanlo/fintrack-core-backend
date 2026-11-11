# frozen_string_literal: true

class AddClusterAlertSources < ActiveRecord::Migration[8.0]
  def up
    create_table :insider_cluster_snapshots do |t|
      t.string :event_key, null: false, index: { unique: true }
      t.string :issuer_cik, null: false
      t.string :issuer_name
      t.string :issuer_ticker
      t.string :transaction_code, null: false
      t.datetime :window_start, null: false
      t.datetime :window_end, null: false
      t.integer :window_days, null: false
      t.integer :definition_minimum_insiders, null: false
      t.integer :insider_count, null: false
      t.integer :transaction_count, null: false
      t.decimal :total_value
      t.decimal :known_value_subtotal
      t.integer :transactions_without_usable_price, null: false
      t.bigint :transaction_ids, array: true, null: false
      t.string :insider_ciks, array: true, null: false
      t.bigint :filing_ids, array: true, null: false
      t.references :primary_filing, null: false, foreign_key: { to_table: :filings }
      t.jsonb :insiders, null: false
      t.datetime :observed_at, null: false
      t.bigint :max_filing_id, null: false
      t.bigint :max_transaction_id, null: false
      t.timestamps
    end
    add_check_constraint :insider_cluster_snapshots, "event_key ~ '^[0-9a-f]{64}$' AND issuer_cik ~ '^[0-9]{10}$' AND transaction_code IN ('P', 'S')", name: "cluster_snapshot_identity"
    add_check_constraint :insider_cluster_snapshots, "window_days > 0 AND window_start < window_end AND observed_at >= window_end AND definition_minimum_insiders >= 3", name: "cluster_snapshot_window"
    add_check_constraint :insider_cluster_snapshots, "insider_count >= definition_minimum_insiders AND insider_count = cardinality(insider_ciks) AND transaction_count = cardinality(transaction_ids) AND transaction_count >= insider_count AND cardinality(filing_ids) > 0 AND primary_filing_id = ANY(filing_ids) AND transactions_without_usable_price BETWEEN 0 AND transaction_count", name: "cluster_snapshot_membership"
    add_reference :alert_deliveries, :insider_cluster_snapshot, foreign_key: true
    remove_check_constraint :alert_deliveries, name: "alert_delivery_source"
    add_check_constraint :alert_deliveries, <<~SQL.squish, name: "alert_delivery_source"
      (event_type = 'new_filing' AND insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL)
      OR (event_type = 'insider_transaction' AND insider_transaction_id IS NOT NULL AND insider_cluster_snapshot_id IS NULL)
      OR (event_type = 'cluster' AND insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NOT NULL)
    SQL
    remove_index :alert_deliveries, name: :index_alert_deliveries_on_alert_rule_id_and_filing_id
    add_index :alert_deliveries, [ :alert_rule_id, :filing_id ], unique: true,
      where: "insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL", name: :index_alert_deliveries_on_alert_rule_id_and_filing_id
    add_index :alert_deliveries, [ :alert_rule_id, :insider_cluster_snapshot_id ], unique: true,
      where: "insider_cluster_snapshot_id IS NOT NULL", name: :index_alert_deliveries_on_rule_and_cluster
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Review cluster alert history before removing its source snapshots"
  end
end
