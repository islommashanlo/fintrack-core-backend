class CreateSubscriptionPlans < ActiveRecord::Migration[7.1]
  def change
    create_table :subscription_plans do |t|
      t.string :name
      t.text :description
      t.integer :price_cents
      t.string :stripe_price_id
      t.boolean :active

      t.timestamps
    end
  end
end
