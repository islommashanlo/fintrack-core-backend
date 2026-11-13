# frozen_string_literal: true

module Api
  module V1
    class AlertRuleParameters
      def self.normalize(values, create: false, trigger: nil)
        allowed = %w[active frequency trigger channels conditions]
        allowed.concat(%w[follow_id scope]) if create
        invalid! unless (values.keys - allowed).empty? && values.any?
        invalid! if values.key?("active") && ![ true, false ].include?(values["active"])
        invalid! if values.key?("frequency") && !AlertRuleSetting::FREQUENCIES.include?(values["frequency"])
        invalid! if values.key?("trigger") && !AlertRule::EVENT_TYPES.include?(values["trigger"])
        invalid! if values.key?("channels") && ![ [ "email" ], [ "in_app" ] ].include?(values["channels"])
        result = values.slice("active", "frequency").symbolize_keys
        result[:channel] = values["channels"].first if values.key?("channels")
        result[:event_type] = values["trigger"] if values.key?("trigger")
        if create
          result[:event_type] ||= "new_filing"
          target_scope = values.fetch("scope", "follow")
          invalid! unless AlertRule::SCOPES.include?(target_scope)
          result[:scope] = target_scope
          if target_scope == "watchlist"
            invalid! if values.key?("follow_id")
          else
            result[:follow_id] = AlertParameters.id!(values["follow_id"].to_s)
          end
        end
        selected_trigger = create ? result[:event_type] : trigger
        invalid! if result[:channel] == "in_app" && !AlertRule::IN_APP_EVENT_TYPES.include?(selected_trigger)
        if values.key?("conditions")
          normalizer = case selected_trigger
          when "cluster" then ClusterAlertConditions
          when "13f_change" then InstitutionalAlertConditions
          when "news" then NewsAlertConditions
          else TransactionAlertConditions
          end
          result[:conditions] = normalizer.normalize(values["conditions"])
        end
        invalid! if selected_trigger == "new_filing" && result[:conditions].present?
        result
      rescue TransactionAlertConditions::Invalid
        invalid!
      end

      def self.invalid!
        raise InvalidParameter, "Invalid filing alert configuration"
      end
    end
  end
end
