# frozen_string_literal: true

class AddNewsSourcesToInAppNotifications < ActiveRecord::Migration[8.0]
  def up
    change_column_null :in_app_notifications, :filing_id, true
    add_reference :in_app_notifications, :news_item, foreign_key: true
    add_reference :in_app_notifications, :news_alert_snapshot, foreign_key: true
    add_index :in_app_notifications, [ :alert_rule_id, :news_item_id ], unique: true,
      where: "event_type = 'news'", name: "in_app_notifications_unique_news"
    remove_check_constraint :in_app_notifications, name: "in_app_notification_source"
    add_check_constraint :in_app_notifications, <<~SQL.squish, name: "in_app_notification_source"
      (event_type = 'news' AND filing_id IS NULL AND news_item_id IS NOT NULL AND news_alert_snapshot_id IS NOT NULL
        AND insider_transaction_id IS NULL AND security_table IS NULL AND txn_seq IS NULL
        AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL)
      OR (filing_id IS NOT NULL AND news_item_id IS NULL AND news_alert_snapshot_id IS NULL AND (
        (event_type = 'new_filing' AND insider_transaction_id IS NULL AND security_table IS NULL
          AND txn_seq IS NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL)
        OR (event_type = 'insider_transaction' AND insider_transaction_id IS NOT NULL
          AND security_table IS NOT NULL AND security_table IN ('non_derivative', 'derivative')
          AND txn_seq IS NOT NULL AND txn_seq > 0 AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL)
        OR (event_type = 'cluster' AND insider_cluster_snapshot_id IS NOT NULL
          AND insider_transaction_id IS NULL AND security_table IS NULL AND txn_seq IS NULL AND institutional_change_snapshot_id IS NULL)
        OR (event_type = '13f_change' AND institutional_change_snapshot_id IS NOT NULL
          AND insider_transaction_id IS NULL AND security_table IS NULL AND txn_seq IS NULL AND insider_cluster_snapshot_id IS NULL)
      ))
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "News notification history has no SEC filing and must be preserved"
  end
end
