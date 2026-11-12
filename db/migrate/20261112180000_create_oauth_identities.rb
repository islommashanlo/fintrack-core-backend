# frozen_string_literal: true

class CreateOauthIdentities < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_identities do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false
      t.string :subject, null: false
      t.timestamps
    end
    add_index :oauth_identities, [ :provider, :subject ], unique: true
    add_index :oauth_identities, [ :user_id, :provider ], unique: true
    add_check_constraint :oauth_identities, "provider = 'google'", name: "oauth_identity_provider"
    add_check_constraint :oauth_identities, "char_length(subject) BETWEEN 1 AND 255", name: "oauth_identity_subject"
  end
end
