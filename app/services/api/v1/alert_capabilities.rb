# frozen_string_literal: true

module Api
  module V1
    class AlertCapabilities
      def self.for_user(user)
        {
          capabilities: {
            rule_creation: true, rule_deletion: true, pause_rules: true,
            resume_rules: true, instant_alerts: !!PlanCatalog.limit_for(user, :instant_alerts),
            daily_digest: true, condition_filters: true, read_tracking: true
          },
          limits: { alert_rules: PlanCatalog.limit_for(user, :alert_rules) },
          supported_triggers: AlertRule::EVENT_TYPES, supported_channels: %w[email],
          transaction_condition_fields: TransactionAlertConditions::ENUMS.keys + %w[codes min_value],
          supported_frequencies: PlanCatalog.limit_for(user, :instant_alerts) ? %w[daily_digest instant] : %w[daily_digest]
        }
      end
    end
  end
end
