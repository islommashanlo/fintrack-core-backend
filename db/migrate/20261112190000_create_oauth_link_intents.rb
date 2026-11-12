# frozen_string_literal: true

class CreateOauthLinkIntents < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_link_intents do |t|
      t.references :session, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :state_digest, null: false
      t.string :nonce_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :oauth_link_intents, :state_digest, unique: true
    add_check_constraint :oauth_link_intents, "state_digest ~ '^[0-9a-f]{64}$' AND nonce_digest ~ '^[0-9a-f]{64}$'", name: "oauth_link_intent_digests"
  end
end
