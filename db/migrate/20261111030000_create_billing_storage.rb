# frozen_string_literal: true

class CreateBillingStorage < ActiveRecord::Migration[8.0]
  def change
    create_table :billing_customers do |t|
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :stripe_id, null: false
      t.boolean :livemode, null: false
      t.timestamps
      t.index %i[stripe_id livemode], unique: true
      t.index %i[user_id livemode], unique: true, where: "user_id IS NOT NULL"
    end

    create_table :billing_events do |t|
      t.string :stripe_id, null: false
      t.string :event_type, null: false
      t.string :api_version, null: false
      t.boolean :livemode, null: false
      t.datetime :provider_created_at, null: false
      t.string :stripe_customer_id
      t.string :stripe_subscription_id
      t.string :payload_digest, null: false
      t.string :status, null: false, default: "pending"
      t.string :reason
      t.integer :attempts, null: false, default: 0
      t.datetime :verified_at, null: false
      t.datetime :processed_at
      t.timestamps
      t.index %i[stripe_id livemode], unique: true
      t.index %i[status created_at]
      t.index %i[stripe_customer_id livemode]
      t.check_constraint "status IN ('pending', 'processed', 'ignored', 'failed', 'needs_review')", name: :billing_event_status
      t.check_constraint "attempts >= 0", name: :billing_event_attempts
    end

    create_table :subscriptions do |t|
      t.references :billing_customer, null: false, foreign_key: true
      t.references :billing_event, null: false, foreign_key: true
      t.string :stripe_id, null: false
      t.boolean :livemode, null: false
      t.string :status, null: false
      t.string :price_id
      t.string :sync_status, null: false, default: "verified"
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.datetime :trial_end
      t.datetime :cancel_at
      t.boolean :cancel_at_period_end, null: false, default: false
      t.boolean :collection_paused, null: false, default: false
      t.datetime :verified_at, null: false
      t.timestamps
      t.index %i[stripe_id livemode], unique: true
      t.index %i[status sync_status current_period_end], name: :index_subscriptions_on_entitlement
      t.check_constraint "status IN ('active', 'trialing', 'past_due', 'canceled', 'unpaid', 'paused', 'incomplete', 'incomplete_expired')", name: :subscription_status
      t.check_constraint "sync_status IN ('verified', 'needs_review')", name: :subscription_sync_status
    end
  end
end
