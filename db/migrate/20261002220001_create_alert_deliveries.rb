# frozen_string_literal: true

class CreateAlertDeliveries < ActiveRecord::Migration[8.0]
  def change
    create_table :alert_deliveries do |t|
      t.references :alert_rule, null: false, foreign_key: true
      t.references :filing, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.datetime :delivered_at
      t.text :error

      t.timestamps
    end

    add_index :alert_deliveries, %i[alert_rule_id filing_id], unique: true
  end
end
