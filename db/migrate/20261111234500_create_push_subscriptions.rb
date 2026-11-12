# frozen_string_literal: true

class CreatePushSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :push_subscriptions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :session, null: false, foreign_key: { on_delete: :cascade }
      t.string :endpoint_digest, null: false
      t.string :endpoint_origin, null: false
      t.text :encrypted_payload, null: false
      t.datetime :expires_at
      t.datetime :consented_at, null: false
      t.timestamps
    end
    add_index :push_subscriptions, :endpoint_digest, unique: true
    add_check_constraint :push_subscriptions, "endpoint_digest ~ '^[0-9a-f]{64}$'", name: "push_subscription_digest"
  end
end
