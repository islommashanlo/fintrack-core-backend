# frozen_string_literal: true

class AddClusterSourcesToInAppNotifications < ActiveRecord::Migration[8.0]
  def up
    add_reference :in_app_notifications, :insider_cluster_snapshot, foreign_key: true
    add_index :in_app_notifications, [ :alert_rule_id, :insider_cluster_snapshot_id ], unique: true,
      where: "event_type = 'cluster'", name: "in_app_notifications_unique_cluster"
    remove_check_constraint :in_app_notifications, name: "in_app_notification_source"
    add_check_constraint :in_app_notifications, <<~SQL.squish, name: "in_app_notification_source"
      (event_type = 'new_filing' AND insider_transaction_id IS NULL AND security_table IS NULL
        AND txn_seq IS NULL AND insider_cluster_snapshot_id IS NULL)
      OR (event_type = 'insider_transaction' AND insider_transaction_id IS NOT NULL
        AND security_table IS NOT NULL AND security_table IN ('non_derivative', 'derivative')
        AND txn_seq IS NOT NULL AND txn_seq > 0 AND insider_cluster_snapshot_id IS NULL)
      OR (event_type = 'cluster' AND insider_cluster_snapshot_id IS NOT NULL
        AND insider_transaction_id IS NULL AND security_table IS NULL AND txn_seq IS NULL)
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Cluster notification history must be preserved"
  end
end
