# frozen_string_literal: true

class EnableWatchlistClusterAlerts < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :alert_rules, name: "alert_rule_watchlist_supported_activation"
    add_check_constraint :alert_rules,
      "scope <> 'watchlist' OR NOT active OR (event_type IN ('new_filing', 'insider_transaction', 'cluster') AND channel IN ('email', 'in_app'))",
      name: "alert_rule_watchlist_supported_activation"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve active watchlist cluster rules with a forward migration"
  end
end
