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
          rule_quota: { used: AlertRuleQuota.count(user), shared_across_channels: true },
          limits: { alert_rules: PlanCatalog.limit_for(user, :alert_rules) },
          supported_scopes: AlertRule::SCOPES, watchlist_activation: true,
          watchlist_in_app_supported_triggers: %w[new_filing insider_transaction cluster], watchlist_email_supported_triggers: %w[new_filing insider_transaction cluster],
          supported_triggers: AlertRule::EVENT_TYPES, supported_channels: %w[email in_app], in_app_supported_triggers: AlertRule::IN_APP_EVENT_TYPES,
          transaction_condition_fields: TransactionAlertConditions::ENUMS.keys + %w[codes min_value],
          cluster_condition_fields: ClusterAlertConditions::FIELDS,
          news_condition_fields: NewsAlertConditions::FIELDS,
          institutional_condition_fields: InstitutionalAlertConditions::FIELDS,
          supported_frequencies: PlanCatalog.limit_for(user, :instant_alerts) ? %w[daily_digest instant] : %w[daily_digest]
        }
      end
    end
  end
end
