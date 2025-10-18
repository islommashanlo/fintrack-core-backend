# frozen_string_literal: true

class AlertSubscription < ApplicationRecord
  self.table_name = 'alert_subscriptions'

  belongs_to :user
  belongs_to :trader, optional: true
end
