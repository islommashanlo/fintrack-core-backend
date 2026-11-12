# frozen_string_literal: true

class NotificationPreference < ApplicationRecord
  belongs_to :user
  validates :user_id, uniqueness: true
  validates :unsubscribe_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :valid_time_zone
  before_validation :record_consent

  private

  def valid_time_zone
    if time_zone.present?
      TZInfo::Timezone.get(time_zone)
    elsif email_enabled?
      errors.add(:time_zone, "must be set before email is enabled")
    end
  rescue TZInfo::InvalidTimezoneIdentifier
    errors.add(:time_zone, "must be a valid IANA time zone")
  end

  def record_consent
    self.push_enabled_at = Time.current if push_enabled? && (will_save_change_to_push_enabled? || push_enabled_at.nil?)
    self.email_enabled_at = Time.current if email_enabled? && (will_save_change_to_email_enabled? || email_enabled_at.nil?)
  end
end
