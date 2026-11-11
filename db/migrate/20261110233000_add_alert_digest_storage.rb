# frozen_string_literal: true

class AddAlertDigestStorage < ActiveRecord::Migration[8.0]
  def change
    add_column :follows, :removed_at, :datetime
    add_index :follows, [ :user_id, :removed_at ]
    change_column_default :alert_rules, :active, from: true, to: false
    add_column :alert_deliveries, :frequency, :string, null: false, default: "instant"
    add_check_constraint :alert_deliveries, "frequency IN ('instant', 'daily_digest')", name: "alert_delivery_frequency"
    create_table :alert_rule_settings do |t|
      t.references :alert_rule, null: false, foreign_key: true, index: { unique: true }
      t.string :frequency, null: false, default: "daily_digest"
      t.jsonb :conditions, null: false, default: {}
      t.datetime :enabled_at
      t.datetime :archived_at
      t.timestamps
    end
    add_index :alert_rule_settings, [ :frequency, :archived_at ]
    add_check_constraint :alert_rule_settings, "frequency IN ('instant', 'daily_digest')", name: "alert_setting_frequency"
    add_check_constraint :alert_rule_settings, "jsonb_typeof(conditions) = 'object'", name: "alert_setting_conditions_object"
    create_table :notification_preferences do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :time_zone
      t.boolean :email_enabled, null: false, default: false
      t.datetime :email_enabled_at
      t.integer :unsubscribe_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :notification_preferences, "unsubscribe_version >= 0", name: "notification_unsubscribe_version"
    create_table :alert_event_states do |t|
      t.references :user, null: false, foreign_key: true
      t.references :alert_delivery, null: false, foreign_key: true
      t.datetime :read_at, null: false
      t.timestamps
    end
    add_index :alert_event_states, [ :user_id, :alert_delivery_id ], unique: true
    add_index :alert_event_states, [ :user_id, :read_at ]
    create_table :alert_digest_batches do |t|
      t.references :user, null: false, foreign_key: true
      t.date :local_date, null: false
      t.string :time_zone, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :started_at
      t.datetime :delivered_at
      t.text :error
      t.timestamps
    end
    add_index :alert_digest_batches, [ :user_id, :local_date ], unique: true
    add_index :alert_digest_batches, [ :status, :created_at ]
    add_check_constraint :alert_digest_batches, "status IN ('pending', 'sending', 'sent', 'failed', 'canceled')", name: "alert_digest_status"
    create_table :alert_digest_items do |t|
      t.references :alert_digest_batch, null: false, foreign_key: true
      t.references :alert_delivery, null: false, foreign_key: true, index: { unique: true }
      t.timestamps
    end
  end
end
