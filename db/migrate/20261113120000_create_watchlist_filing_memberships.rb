# frozen_string_literal: true

class CreateWatchlistFilingMemberships < ActiveRecord::Migration[8.0]
  def up
    add_index :alert_rules, [ :id, :user_id ], unique: true, name: "index_alert_rules_on_id_and_owner"
    add_index :in_app_notifications, [ :id, :alert_rule_id, :filing_id ], unique: true, name: "index_notifications_on_id_rule_filing"
    create_table :watchlist_filing_memberships do |t|
      t.references :in_app_notification, null: false, foreign_key: true
      t.references :alert_rule, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :filing, null: false, foreign_key: true
      t.references :follow, null: false, foreign_key: true
      t.datetime :followed_at, null: false
      t.string :target_type, null: false
      t.string :target_key, null: false
      t.timestamps
      t.index [ :in_app_notification_id, :follow_id, :followed_at ], unique: true, name: "index_watchlist_membership_witness"
      t.check_constraint "target_type IN ('Ticker', 'Insider', 'InstitutionalFiler')", name: "watchlist_membership_target_type"
    end
    add_foreign_key :watchlist_filing_memberships, :follows, column: [ :follow_id, :user_id ],
      primary_key: [ :id, :user_id ], name: "fk_watchlist_membership_follow_owner"
    add_foreign_key :watchlist_filing_memberships, :alert_rules, column: [ :alert_rule_id, :user_id ],
      primary_key: [ :id, :user_id ], name: "fk_watchlist_membership_rule_owner"
    add_foreign_key :watchlist_filing_memberships, :in_app_notifications,
      column: [ :in_app_notification_id, :alert_rule_id, :filing_id ], primary_key: [ :id, :alert_rule_id, :filing_id ],
      name: "fk_watchlist_membership_notification_source"
    remove_check_constraint :alert_rules, name: "alert_rule_watchlist_draft"
    add_check_constraint :alert_rules,
      "scope <> 'watchlist' OR NOT active OR (event_type = 'new_filing' AND channel = 'in_app')",
      name: "alert_rule_watchlist_supported_activation"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve notification membership evidence with a forward migration"
  end
end
