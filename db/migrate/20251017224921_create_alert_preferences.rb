class CreateAlertPreferences < ActiveRecord::Migration[7.1]
  def change
    create_table :alert_preferences do |t|
      t.references :user, null: false, foreign_key: true
      t.string :ticker
      t.string :source_type
      t.string :person_name
      t.boolean :active

      t.timestamps
    end
  end
end
