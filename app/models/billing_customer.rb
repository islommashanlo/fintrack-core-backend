# frozen_string_literal: true

class BillingCustomer < ApplicationRecord
  belongs_to :user, optional: true
  has_many :subscriptions, dependent: :restrict_with_exception
  validates :stripe_id, format: { with: /\Acus_[A-Za-z0-9_]{1,200}\z/ }
  validates :livemode, inclusion: { in: [ true, false ] }
end
