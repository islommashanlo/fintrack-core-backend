# frozen_string_literal: true

class BillingEvent < ApplicationRecord
  STATUSES = %w[pending processed ignored failed needs_review].freeze
  has_many :subscriptions, dependent: :restrict_with_exception
  validates :stripe_id, :event_type, :api_version, :payload_digest, :verified_at, :provider_created_at, presence: true
  validates :status, inclusion: { in: STATUSES }
end
