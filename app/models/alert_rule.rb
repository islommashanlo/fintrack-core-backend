# frozen_string_literal: true

class AlertRule < ApplicationRecord
  EVENT_TYPES = %w[new_filing].freeze
  CHANNELS = %w[email].freeze

  belongs_to :follow
  has_one :user, through: :follow
  has_many :alert_deliveries, dependent: :restrict_with_exception

  scope :active, -> { where(active: true) }

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :channel, inclusion: { in: CHANNELS }
  validates :channel, uniqueness: { scope: %i[follow_id event_type] }
end
