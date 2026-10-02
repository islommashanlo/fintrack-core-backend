# frozen_string_literal: true

class CreateFollows < ActiveRecord::Migration[8.0]
  def change
    create_table :follows do |t|
      t.references :user, null: false, foreign_key: true
      t.string :target_type, null: false
      t.string :target_key, null: false

      t.timestamps
    end

    add_index :follows, %i[user_id target_type target_key], unique: true
  end
end
