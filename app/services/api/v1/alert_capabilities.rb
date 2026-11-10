# frozen_string_literal: true

module Api
  module V1
    class AlertCapabilities
      def self.for_user(user)
        {
          capabilities: {
            rule_creation: false, rule_deletion: false, pause_rules: true,
            resume_rules: !!PlanCatalog.limit_for(user, :instant_alerts),
            daily_digest: false, condition_filters: false, read_tracking: false
          },
          limits: { alert_rules: PlanCatalog.limit_for(user, :alert_rules) },
          supported_triggers: %w[new_filing], supported_channels: %w[email], supported_frequencies: %w[instant]
        }
      end
    end
  end
end
