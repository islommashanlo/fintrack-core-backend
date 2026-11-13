# frozen_string_literal: true

class CreateWatchlistNewsMemberships < ActiveRecord::Migration[8.0]
  def up
    add_index :in_app_notifications, [ :id, :alert_rule_id, :news_item_id ], unique: true, name: "index_notifications_on_id_rule_news"
    add_index :alert_deliveries, [ :id, :alert_rule_id, :news_item_id ], unique: true, name: "index_deliveries_on_id_rule_news"
    add_index :news_alert_snapshots, [ :id, :news_item_id ], unique: true, name: "index_news_snapshots_on_id_item"
    create_table :watchlist_news_memberships do |t|
      t.references :in_app_notification, foreign_key: true
      t.references :alert_delivery, foreign_key: true
      t.references :alert_rule, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :follow, null: false, foreign_key: true
      t.references :news_item, null: false, foreign_key: true
      t.references :news_alert_snapshot, null: false, foreign_key: true
      t.datetime :followed_at, null: false
      t.string :target_type, null: false
      t.string :target_key, null: false
      t.timestamps
      t.check_constraint "(in_app_notification_id IS NULL) <> (alert_delivery_id IS NULL)", name: "watchlist_news_destination"
      t.check_constraint "target_type IN ('Ticker', 'Insider', 'InstitutionalFiler')", name: "watchlist_news_target_type"
      t.index [ :in_app_notification_id, :follow_id, :followed_at ], unique: true, name: "watchlist_news_unique_notification_witness"
      t.index [ :alert_delivery_id, :follow_id, :followed_at ], unique: true, name: "watchlist_news_unique_delivery_witness"
    end
    add_foreign_key :watchlist_news_memberships, :follows, column: [ :follow_id, :user_id ], primary_key: [ :id, :user_id ], name: "fk_watchlist_news_follow_owner"
    add_foreign_key :watchlist_news_memberships, :alert_rules, column: [ :alert_rule_id, :user_id ], primary_key: [ :id, :user_id ], name: "fk_watchlist_news_rule_owner"
    add_foreign_key :watchlist_news_memberships, :in_app_notifications,
      column: [ :in_app_notification_id, :alert_rule_id, :news_item_id ], primary_key: [ :id, :alert_rule_id, :news_item_id ], name: "fk_watchlist_news_notification_source"
    add_foreign_key :watchlist_news_memberships, :alert_deliveries,
      column: [ :alert_delivery_id, :alert_rule_id, :news_item_id ], primary_key: [ :id, :alert_rule_id, :news_item_id ], name: "fk_watchlist_news_delivery_source"
    add_foreign_key :watchlist_news_memberships, :news_alert_snapshots,
      column: [ :news_alert_snapshot_id, :news_item_id ], primary_key: [ :id, :news_item_id ], name: "fk_watchlist_news_snapshot_source"
    remove_check_constraint :alert_rules, name: "alert_rule_watchlist_supported_activation"
    add_check_constraint :alert_rules,
      "scope <> 'watchlist' OR NOT active OR (event_type IN ('new_filing', 'insider_transaction', 'cluster', '13f_change', 'news') AND channel IN ('email', 'in_app'))",
      name: "alert_rule_watchlist_supported_activation"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve captured news membership with a forward migration"
  end
end
