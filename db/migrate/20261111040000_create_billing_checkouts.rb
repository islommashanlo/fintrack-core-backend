# frozen_string_literal: true

class CreateBillingCheckouts < ActiveRecord::Migration[8.0]
  def change
    create_table :billing_checkouts do |t|
      t.references :user, null: false, foreign_key: true
      t.references :billing_customer, foreign_key: true
      t.string :request_id, null: false
      t.boolean :livemode, null: false
      t.string :interval, null: false
      t.string :price_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :stripe_id
      t.text :success_url, null: false
      t.text :cancel_url, null: false
      t.datetime :expires_at
      t.timestamps
      t.index %i[user_id livemode request_id], unique: true
      t.index %i[user_id livemode status]
      t.check_constraint "status IN ('pending', 'open', 'complete', 'expired', 'needs_review')", name: :billing_checkout_status
      t.check_constraint "interval IN ('month', 'year')", name: :billing_checkout_interval
    end
  end
end
