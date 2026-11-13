# frozen_string_literal: true

class AddFlowToOauthLinkIntents < ActiveRecord::Migration[8.0]
  def up
    add_column :oauth_link_intents, :flow, :string, null: false, default: "id_token"
    add_check_constraint :oauth_link_intents, "flow IN ('id_token', 'code')", name: "oauth_link_intent_flow"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve protocol separation for pending linking intents"
  end
end
