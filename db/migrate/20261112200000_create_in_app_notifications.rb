# frozen_string_literal: true

class CreateInAppNotifications < ActiveRecord::Migration[8.0]
  def change
    create_table :in_app_notifications do |t|
      t.references :alert_rule, null: false, foreign_key: true
      t.references :filing, null: false, foreign_key: true
      t.integer :rule_revision, null: false
      t.string :frequency, null: false
      t.string :time_zone
      t.datetime :available_at, null: false
      t.datetime :published_at
      t.datetime :read_at
      t.timestamps
    end
    add_index :in_app_notifications, [ :alert_rule_id, :filing_id ], unique: true
    add_index :in_app_notifications, [ :published_at, :id ]
    add_index :in_app_notifications, :available_at, where: "published_at IS NULL", name: "in_app_notifications_pending"
    add_check_constraint :in_app_notifications, "rule_revision > 0 AND frequency IN ('instant', 'daily_digest')", name: "in_app_notification_configuration"
    add_check_constraint :in_app_notifications, "read_at IS NULL OR published_at IS NOT NULL", name: "in_app_notification_read_state"
  end
end
