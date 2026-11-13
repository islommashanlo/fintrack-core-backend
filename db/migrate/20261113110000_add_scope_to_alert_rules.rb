# frozen_string_literal: true

class AddScopeToAlertRules < ActiveRecord::Migration[8.0]
  def up
    add_column :alert_rules, :scope, :string, null: false, default: "follow"
    change_column_null :alert_rules, :follow_id, true
    add_check_constraint :alert_rules,
      "(scope = 'follow' AND follow_id IS NOT NULL) OR (scope = 'watchlist' AND follow_id IS NULL)",
      name: "alert_rule_scope_target"
    add_check_constraint :alert_rules, "scope <> 'watchlist' OR NOT active", name: "alert_rule_watchlist_draft"
    add_index :alert_rules, [ :user_id, :event_type, :channel ], unique: true,
      where: "scope = 'watchlist'", name: "index_watchlist_alert_rules_on_owner_trigger_channel"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Watchlist drafts must be preserved; use a data-preserving forward migration"
  end
end
