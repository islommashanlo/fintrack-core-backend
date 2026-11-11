# frozen_string_literal: true

class AddCheckoutSubscriptionReference < ActiveRecord::Migration[8.0]
  def change
    add_column :billing_checkouts, :stripe_subscription_id, :string
  end
end
