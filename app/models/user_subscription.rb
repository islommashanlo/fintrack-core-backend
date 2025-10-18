# frozen_string_literal: true

class UserSubscription < ApplicationRecord
  belongs_to :user
  belongs_to :subscription_plan

  validates :stripe_customer_id, presence: true
  validates :stripe_subscription_id, presence: true
  validates :status, presence: true

  # Enum for subscription status
  enum status: {
    incomplete: 'incomplete',
    incomplete_expired: 'incomplete_expired',
    trialing: 'trialing',
    active: 'active',
    past_due: 'past_due',
    canceled: 'canceled',
    unpaid: 'unpaid'
  }

  scope :active, -> { where(status: :active) }
  scope :canceled, -> { where(status: :canceled) }

  def active?
    status == 'active'
  end

  def canceled?
    status == 'canceled'
  end

  def expired?
    return false if current_period_end.blank?

    current_period_end < Time.current
  end

  def self.ransackable_attributes(_auth_object = nil)
    %w[status current_period_start current_period_end cancel_at_period_end]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[user subscription_plan]
  end
end
