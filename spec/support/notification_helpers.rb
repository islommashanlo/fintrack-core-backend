# frozen_string_literal: true

module NotificationHelpers
  def consent_email(user, zone: "America/New_York")
    preference = NotificationPreferences.update(user:, attributes: { time_zone: zone, email_enabled: true })
    preference.update_columns(email_enabled_at: 1.year.ago)
    preference
  end

  def enable_rule(rule, frequency: "daily_digest")
    rule.setting.update!(frequency:)
    rule.update!(active: true)
    rule.setting.update!(enabled_at: 1.year.ago)
    rule
  end
end

RSpec.configure { |config| config.include NotificationHelpers }
