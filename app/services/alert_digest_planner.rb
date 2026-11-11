# frozen_string_literal: true

class AlertDigestPlanner
  def self.call(user:, as_of: Time.current)
    user.with_lock do
      preference = user.notification_preference
      return unless preference&.email_enabled? && preference.time_zone.present?
      local = as_of.in_time_zone(preference.time_zone)
      cutoff = local.change(hour: 7, min: 0, sec: 0, usec: 0)
      return if local < cutoff

      existing = user.alert_digest_batches.find_by(local_date: local.to_date)
      return existing if existing
      eligible = user.alert_deliveries.joins(alert_rule: :setting)
        .where(frequency: "daily_digest", status: %w[pending failed])
        .where(alert_rules: { active: true }, alert_rule_settings: { archived_at: nil, frequency: "daily_digest" }, follows: { removed_at: nil })
        .where("alert_deliveries.rule_revision = alert_rule_settings.revision")
        .where("alert_deliveries.created_at < ? AND alert_deliveries.created_at >= ? AND alert_deliveries.created_at >= alert_rule_settings.enabled_at",
          cutoff, preference.email_enabled_at)
        .where.not(id: AlertDigestItem.select(:alert_delivery_id))
      eligible = AlertSourceValidity.apply(eligible, as_of:)
      return unless eligible.exists?

      batch = user.alert_digest_batches.create!(local_date: local.to_date, time_zone: preference.time_zone)
      now = Time.current
      connection = ApplicationRecord.connection
      # The relation is already quoted SQL. Do not reinterpret regex/JSON syntax
      # inside it as named bind parameters in a second sanitization pass.
      sql = <<~SQL
        INSERT INTO alert_digest_items (alert_digest_batch_id, alert_delivery_id, created_at, updated_at)
        SELECT #{connection.quote(batch.id)}, chosen.id, #{connection.quote(now)}, #{connection.quote(now)}
        FROM (#{eligible.select('alert_deliveries.id').to_sql}) chosen
        ON CONFLICT (alert_delivery_id) DO NOTHING
      SQL
      connection.execute(sql)
      batch
    end
  end
end
