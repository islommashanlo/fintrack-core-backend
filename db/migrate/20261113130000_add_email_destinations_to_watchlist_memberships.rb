# frozen_string_literal: true

class AddEmailDestinationsToWatchlistMemberships < ActiveRecord::Migration[8.0]
  def up
    add_index :alert_deliveries, [ :id, :alert_rule_id, :filing_id ], unique: true, name: "index_deliveries_on_id_rule_filing"
    add_reference :watchlist_filing_memberships, :alert_delivery, foreign_key: true
    change_column_null :watchlist_filing_memberships, :in_app_notification_id, true
    add_check_constraint :watchlist_filing_memberships,
      "(in_app_notification_id IS NULL) <> (alert_delivery_id IS NULL)", name: "watchlist_membership_destination"
    add_index :watchlist_filing_memberships, [ :alert_delivery_id, :follow_id, :followed_at ],
      unique: true, name: "index_watchlist_email_membership_witness"
    add_foreign_key :watchlist_filing_memberships, :alert_deliveries,
      column: [ :alert_delivery_id, :alert_rule_id, :filing_id ], primary_key: [ :id, :alert_rule_id, :filing_id ],
      name: "fk_watchlist_membership_delivery_source"
    remove_check_constraint :alert_rules, name: "alert_rule_watchlist_supported_activation"
    add_check_constraint :alert_rules,
      "scope <> 'watchlist' OR NOT active OR (event_type = 'new_filing' AND channel IN ('email', 'in_app'))",
      name: "alert_rule_watchlist_supported_activation"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve email membership evidence with a forward migration"
  end
end
