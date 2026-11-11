# frozen_string_literal: true

class ScheduleAlertDigestsJob < ApplicationJob
  queue_as :alerts

  def perform
    now = Time.current
    quoted = ApplicationRecord.connection.quote(now)
    users = User.where(id: NotificationPreference.where(email_enabled: true).where.not(time_zone: nil).select(:user_id))
      .where(<<~SQL)
        EXISTS (SELECT 1 FROM notification_preferences p
          INNER JOIN pg_timezone_names z ON z.name = p.time_zone
          WHERE p.user_id = users.id
            AND (#{quoted}::timestamp AT TIME ZONE 'UTC' AT TIME ZONE p.time_zone)::time >= TIME '07:00'
        )
      SQL
    users.find_each do |user|
      batch = AlertDigestPlanner.call(user:, as_of: now)
      SendAlertDigestJob.perform_later(batch.id) if batch && %w[pending failed].include?(batch.status)
    end
  end
end
