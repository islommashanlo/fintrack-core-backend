# frozen_string_literal: true

class AlertDigestBatch < ApplicationRecord
  STATUSES = %w[pending sending sent failed canceled].freeze
  belongs_to :user
  has_many :alert_digest_items, dependent: :restrict_with_exception
  has_many :alert_deliveries, through: :alert_digest_items
  validates :status, inclusion: { in: STATUSES }
  validates :local_date, :time_zone, presence: true
  validates :local_date, uniqueness: { scope: :user_id }
end
