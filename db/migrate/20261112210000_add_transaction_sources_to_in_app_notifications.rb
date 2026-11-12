# frozen_string_literal: true

class AddTransactionSourcesToInAppNotifications < ActiveRecord::Migration[8.0]
  def up
    add_column :in_app_notifications, :event_type, :string, null: false, default: "new_filing"
    add_reference :in_app_notifications, :insider_transaction, foreign_key: true
    add_column :in_app_notifications, :security_table, :string
    add_column :in_app_notifications, :txn_seq, :integer
    remove_index :in_app_notifications, name: "index_in_app_notifications_on_alert_rule_id_and_filing_id"
    add_index :in_app_notifications, [ :alert_rule_id, :filing_id ], unique: true,
      where: "event_type = 'new_filing'", name: "in_app_notifications_unique_filing"
    add_index :in_app_notifications, [ :alert_rule_id, :filing_id, :security_table, :txn_seq ], unique: true,
      where: "event_type = 'insider_transaction'", name: "in_app_notifications_unique_transaction"
    add_check_constraint :in_app_notifications, <<~SQL.squish, name: "in_app_notification_source"
      (event_type = 'new_filing' AND insider_transaction_id IS NULL AND security_table IS NULL AND txn_seq IS NULL)
      OR (event_type = 'insider_transaction' AND insider_transaction_id IS NOT NULL
        AND security_table IS NOT NULL AND security_table IN ('non_derivative', 'derivative') AND txn_seq IS NOT NULL AND txn_seq > 0)
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Transaction notification history cannot fit the previous filing-only key"
  end
end
