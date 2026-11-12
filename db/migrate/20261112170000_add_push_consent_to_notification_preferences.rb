# frozen_string_literal: true

class AddPushConsentToNotificationPreferences < ActiveRecord::Migration[8.0]
  def change
    add_column :notification_preferences, :push_enabled, :boolean, null: false, default: false
    add_column :notification_preferences, :push_enabled_at, :datetime
  end
end
