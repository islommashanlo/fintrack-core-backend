class CreateUserSubscriptions < ActiveRecord::Migration[7.1]
  def change
    create_table :user_subscriptions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :subscription_plan, null: false, foreign_key: true
      t.string :stripe_customer_id
      t.string :stripe_subscription_id
      t.string :status
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.boolean :cancel_at_period_end

      t.timestamps
    end
  end
end
