class CreateTradeSources < ActiveRecord::Migration[7.1]
  def change
    create_table :trade_sources do |t|
      t.string :name
      t.string :source_type
      t.text :bio
      t.string :position

      t.timestamps
    end
  end
end
