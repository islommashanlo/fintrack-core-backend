# frozen_string_literal: true

class AlertRule < ApplicationRecord
  EVENT_TYPES = %w[new_filing insider_transaction cluster 13f_change news].freeze
  IN_APP_EVENT_TYPES = %w[new_filing insider_transaction].freeze
  CHANNELS = %w[email in_app].freeze

  belongs_to :follow
  has_one :user, through: :follow
  has_many :in_app_notifications, dependent: :restrict_with_exception
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
  validate do
    errors.add(:channel, "does not support this trigger") if channel == "in_app" && !IN_APP_EVENT_TYPES.include?(event_type)
    if event_type.in?(%w[insider_transaction cluster]) && follow&.target_type == "InstitutionalFiler"
      errors.add(:event_type, "requires an issuer or person follow")
    end
    if event_type == "13f_change" && follow&.target_type != "InstitutionalFiler"
      errors.add(:event_type, "requires a fund follow")
    end
  end
end
