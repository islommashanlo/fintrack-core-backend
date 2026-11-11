# frozen_string_literal: true

class CreateUserPreferences < ActiveRecord::Migration[8.0]
  def change
    create_table :user_preferences do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :theme, null: false, default: "system"
      t.string :dashboard_layout, null: false, default: "split"
      t.timestamps

      t.check_constraint "theme IN ('system', 'light', 'dark')", name: :user_preference_theme
      t.check_constraint "dashboard_layout IN ('split', 'focus', 'columns')", name: :user_preference_dashboard_layout
    end
  end
end
