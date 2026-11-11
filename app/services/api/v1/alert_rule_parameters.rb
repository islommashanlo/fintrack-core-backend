# frozen_string_literal: true

module Api
  module V1
    class AlertRuleParameters
      def self.normalize(values, create: false)
        allowed = %w[active frequency trigger channels conditions]
        allowed << "follow_id" if create
        invalid! unless (values.keys - allowed).empty? && values.any?
        invalid! if values.key?("active") && ![ true, false ].include?(values["active"])
        invalid! if values.key?("frequency") && !AlertRuleSetting::FREQUENCIES.include?(values["frequency"])
        invalid! if values.key?("trigger") && values["trigger"] != "new_filing"
        invalid! if values.key?("channels") && values["channels"] != [ "email" ]
        invalid! if values.key?("conditions") && values["conditions"] != {}
        result = values.slice("active", "frequency").symbolize_keys
        if create
          result[:follow_id] = AlertParameters.id!(values["follow_id"].to_s)
        end
        result
      end

      def self.invalid!
        raise InvalidParameter, "Invalid filing alert configuration"
      end
    end
  end
end
