# frozen_string_literal: true

module Api
  module V1
    class AlertRuleParameters
      def self.normalize(values, create: false, trigger: nil)
        allowed = %w[active frequency trigger channels conditions]
        allowed << "follow_id" if create
        invalid! unless (values.keys - allowed).empty? && values.any?
        invalid! if values.key?("active") && ![ true, false ].include?(values["active"])
        invalid! if values.key?("frequency") && !AlertRuleSetting::FREQUENCIES.include?(values["frequency"])
        invalid! if values.key?("trigger") && !AlertRule::EVENT_TYPES.include?(values["trigger"])
        invalid! if values.key?("channels") && values["channels"] != [ "email" ]
        result = values.slice("active", "frequency").symbolize_keys
        result[:event_type] = values["trigger"] if values.key?("trigger")
        if create
          result[:event_type] ||= "new_filing"
          result[:follow_id] = AlertParameters.id!(values["follow_id"].to_s)
        end
        selected_trigger = create ? result[:event_type] : trigger
        if values.key?("conditions")
          normalizer = selected_trigger == "cluster" ? ClusterAlertConditions : TransactionAlertConditions
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
