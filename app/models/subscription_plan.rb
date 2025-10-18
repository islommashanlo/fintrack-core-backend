# frozen_string_literal: true

class SubscriptionPlan < ApplicationRecord
  validates :name, presence: true, length: { maximum: 255 }
  validates :price_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :stripe_price_id, presence: true, uniqueness: true

  has_many :user_subscriptions, dependent: :destroy

  scope :active, -> { where(active: true) }

  def price_in_dollars
    price_cents.to_f / 100
  end

  def self.ransackable_attributes(_auth_object = nil)
    %w[name price_cents active]
  end
end
