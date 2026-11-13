# frozen_string_literal: true

class AddDirectOwnershipToAlertRules < ActiveRecord::Migration[8.0]
  def up
    add_reference :alert_rules, :user, foreign_key: true
    execute <<~SQL
      UPDATE alert_rules rules
      SET user_id = follows.user_id
      FROM follows WHERE follows.id = rules.follow_id
    SQL
    change_column_null :alert_rules, :user_id, false
    add_index :follows, [ :id, :user_id ], unique: true, name: "index_follows_on_id_and_owner"
    add_foreign_key :alert_rules, :follows, column: [ :follow_id, :user_id ],
      primary_key: [ :id, :user_id ], name: "fk_alert_rules_follow_owner"
  end

  def down
    remove_foreign_key :alert_rules, name: "fk_alert_rules_follow_owner"
    remove_index :follows, name: "index_follows_on_id_and_owner"
    remove_reference :alert_rules, :user, foreign_key: true
  end
end
