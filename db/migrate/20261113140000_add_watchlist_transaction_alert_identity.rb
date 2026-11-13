# frozen_string_literal: true

class AddWatchlistTransactionAlertIdentity < ActiveRecord::Migration[8.0]
  def up
    add_column :alert_deliveries, :watchlist_security_table, :string
    add_column :alert_deliveries, :watchlist_txn_seq, :integer
    add_check_constraint :alert_deliveries, <<~SQL.squish, name: "watchlist_delivery_transaction_identity"
      (watchlist_security_table IS NULL AND watchlist_txn_seq IS NULL) OR (
        event_type = 'insider_transaction' AND insider_transaction_id IS NOT NULL
        AND watchlist_security_table IS NOT NULL AND watchlist_txn_seq IS NOT NULL
        AND watchlist_security_table IN ('non_derivative', 'derivative') AND watchlist_txn_seq > 0)
    SQL
    add_index :alert_deliveries, [ :alert_rule_id, :filing_id, :watchlist_security_table, :watchlist_txn_seq ],
      unique: true, where: "watchlist_txn_seq IS NOT NULL", name: "watchlist_delivery_unique_transaction_line"
    add_index :insider_transactions, [ :id, :filing_id, :security_table, :txn_seq ],
      unique: true, name: "index_transactions_on_id_filing_table_seq"
    add_foreign_key :alert_deliveries, :insider_transactions,
      column: [ :insider_transaction_id, :filing_id, :watchlist_security_table, :watchlist_txn_seq ],
      primary_key: [ :id, :filing_id, :security_table, :txn_seq ], name: "fk_watchlist_delivery_transaction_line"
    remove_check_constraint :alert_rules, name: "alert_rule_watchlist_supported_activation"
    add_check_constraint :alert_rules,
      "scope <> 'watchlist' OR NOT active OR (event_type IN ('new_filing', 'insider_transaction') AND channel IN ('email', 'in_app'))",
      name: "alert_rule_watchlist_supported_activation"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve transaction alert identity with a forward migration"
  end
end
