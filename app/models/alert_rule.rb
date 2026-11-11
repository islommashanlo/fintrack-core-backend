# frozen_string_literal: true

class AlertRule < ApplicationRecord
  EVENT_TYPES = %w[new_filing].freeze
  CHANNELS = %w[email].freeze

  belongs_to :follow
  has_one :user, through: :follow
  has_many :alert_deliveries, dependent: :restrict_with_exception
  has_one :setting, class_name: "AlertRuleSetting", dependent: :destroy

  scope :active, -> { where(active: true) }
  scope :retained, -> { left_outer_joins(:setting).where(alert_rule_settings: { archived_at: nil }) }

  after_create { create_setting! unless setting }
  after_save do
    setting&.update!(enabled_at: Time.current) if active? && saved_change_to_active?
  end

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :channel, inclusion: { in: CHANNELS }
  validates :channel, uniqueness: { scope: %i[follow_id event_type] }
end
