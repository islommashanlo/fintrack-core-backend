# frozen_string_literal: true

class CreateSavedScreens < ActiveRecord::Migration[8.0]
  def change
    create_table :saved_screens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false, limit: 100
      t.string :entity, null: false
      t.jsonb :filters, null: false, default: []
      t.string :sort, null: false, default: "name"
      t.integer :window_days
      t.timestamps

      t.index "user_id, LOWER(name)", unique: true, name: :index_saved_screens_on_user_and_name
      t.index %i[user_id entity created_at id]
      t.check_constraint "char_length(btrim(name)) BETWEEN 1 AND 100", name: :saved_screen_name
      t.check_constraint "entity IN ('companies', 'funds', 'insiders')", name: :saved_screen_entity
      t.check_constraint "jsonb_typeof(filters) = 'array'", name: :saved_screen_filters
      t.check_constraint <<~SQL.squish, name: :saved_screen_window
        (entity = 'funds' AND window_days IS NULL) OR
        (entity IN ('companies', 'insiders') AND window_days IS NOT NULL AND window_days IN (30, 90, 365))
      SQL
    end
  end
end
