# frozen_string_literal: true

module Api
  module V1
    class AlertParameters
      RULES = %w[scope active trigger entity_type sort limit cursor].freeze
      EVENTS = %w[status trigger rule_id entity_type date_from date_to unread sort limit cursor].freeze

      def self.normalize(values, kind:)
        allowed = kind == :rules ? RULES : EVENTS
        invalid! unless (values.keys - allowed).empty?
        if values["entity_type"]
          invalid! unless WatchlistTarget::TYPES.key?(values["entity_type"])
        end
        invalid! if values["scope"] && !AlertRule::SCOPES.include?(values["scope"])
        invalid! if values["active"] && !%w[true false].include?(values["active"])
        invalid! if values["unread"] && !%w[true false].include?(values["unread"])
        invalid! if values["status"] && !AlertDelivery::STATUSES.include?(values["status"])
        invalid! if values["trigger"] && !AlertRule::EVENT_TYPES.include?(values["trigger"])
        values["rule_id"] = id!(values["rule_id"]).to_s if values["rule_id"]
        %w[date_from date_to].each do |key|
          next unless values[key]

          invalid! unless values[key].match?(/\A\d{4}-\d{2}-\d{2}\z/)
          date = Date.iso8601(values[key], Date::GREGORIAN)
          invalid! unless date.year.between?(1, 9999)
          values[key] = date.iso8601
        end
        invalid! if values.values_at("date_from", "date_to").all? && values["date_from"] > values["date_to"]
        values
      rescue Date::Error
        invalid!
      end

      def self.id!(value)
        invalid! unless value.is_a?(String) && value.match?(/\A[1-9]\d{0,18}\z/) && value.to_i <= 9_223_372_036_854_775_807
        value.to_i
      end

      def self.invalid!
        raise InvalidParameter, "Invalid alert parameters"
      end
    end
  end
end
