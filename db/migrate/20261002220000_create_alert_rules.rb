# frozen_string_literal: true

class CreateAlertRules < ActiveRecord::Migration[8.0]
  def change
    create_table :alert_rules do |t|
      t.references :follow, null: false, foreign_key: true
      t.string :event_type, null: false, default: "new_filing"
      t.string :channel, null: false, default: "email"
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :alert_rules, %i[follow_id event_type channel], unique: true
  end
end
