# frozen_string_literal: true

module Api
  module V1
    class AlertRuleSerializer
      def self.render(rule, as_of: Time.current)
        {
          id: rule.id, follow_id: rule.follow_id, trigger: rule.event_type,
          entity: { type: WatchlistTarget::API_TYPES.fetch(rule.follow.target_type), key: rule.follow.target_key },
          conditions: rule.setting&.conditions || {}, channels: [ rule.channel ], frequency: rule.setting&.frequency || "instant", active: rule.active,
          created_at: rule.created_at, updated_at: rule.updated_at
        }
      end
    end
  end
end
