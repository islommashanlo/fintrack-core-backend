# frozen_string_literal: true

class NotificationPreferences
  def self.update(user:, attributes:)
    user.with_lock do
      preference = user.notification_preference || user.build_notification_preference
      preference.assign_attributes(attributes)
      preference.unsubscribe_version += 1 if preference.will_save_change_to_email_enabled? || preference.will_save_change_to_time_zone?
      preference.save!
      preference
    end
  end
end
