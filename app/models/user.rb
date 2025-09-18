class User < ApplicationRecord
  self.table_name = "users"

  has_many :alert_subscriptions, dependent: :destroy
end


