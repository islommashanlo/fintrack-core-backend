# frozen_string_literal: true

class Subscription < ApplicationRecord
  STATUSES = %w[active trialing past_due canceled unpaid paused incomplete incomplete_expired].freeze
  TERMINAL_STATUSES = %w[canceled incomplete_expired].freeze
  belongs_to :billing_customer
  belongs_to :billing_event
  validates :status, inclusion: { in: STATUSES }
  validates :sync_status, inclusion: { in: %w[verified needs_review] }
  validates :stripe_id, :verified_at, presence: true
end
