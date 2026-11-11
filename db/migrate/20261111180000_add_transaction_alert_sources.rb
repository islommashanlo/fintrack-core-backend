# frozen_string_literal: true

class AddTransactionAlertSources < ActiveRecord::Migration[8.0]
  def up
    add_reference :alert_deliveries, :insider_transaction, foreign_key: true
    add_column :alert_deliveries, :event_type, :string, null: false, default: "new_filing"
    add_column :alert_deliveries, :rule_revision, :bigint, null: false, default: 1
    add_column :alert_rule_settings, :revision, :bigint, null: false, default: 1
    add_check_constraint :alert_deliveries, "rule_revision > 0", name: "alert_delivery_revision"
    add_check_constraint :alert_rule_settings, "revision > 0", name: "alert_setting_revision"
    add_check_constraint :alert_deliveries, <<~SQL.squish, name: "alert_delivery_source"
      (event_type = 'new_filing' AND insider_transaction_id IS NULL)
      OR (event_type = 'insider_transaction' AND insider_transaction_id IS NOT NULL)
    SQL
    remove_index :alert_deliveries, name: :index_alert_deliveries_on_alert_rule_id_and_filing_id
    add_index :alert_deliveries, [ :alert_rule_id, :filing_id ], unique: true,
      where: "insider_transaction_id IS NULL", name: :index_alert_deliveries_on_alert_rule_id_and_filing_id
    add_index :alert_deliveries, [ :alert_rule_id, :insider_transaction_id ], unique: true,
      where: "insider_transaction_id IS NOT NULL", name: :index_alert_deliveries_on_rule_and_transaction
    add_index :alert_rules, [ :event_type, :follow_id ], where: "active", name: :index_active_alert_rules_on_trigger_and_follow
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Review transaction alert history before removing its source references"
  end
end
