# frozen_string_literal: true

module Api
  module V1
    class ActivityParameters
      FILTERS = %w[source direction type level min_score min_value sector date_from date_to watchlist_only].freeze
      PARAMETERS = (FILTERS + %w[sort limit cursor]).freeze

      def self.normalize(values)
        values = values.dup
        values["watchlist_only"] ||= "false"
        values["type"] ||= "all"
        enums = {
          "source" => %w[insider institutional 13dg 144], "direction" => %w[purchase sale other increase decrease],
          "type" => %w[all open_market administrative], "level" => %w[normal elevated high unusual],
          "watchlist_only" => %w[true false]
        }
        enums.each { |key, allowed| invalid!(key) if values[key] && !allowed.include?(values[key]) }
        if values["min_score"]
          invalid!("min_score") unless values["min_score"].match?(/\A\d{1,3}\z/) && values["min_score"].to_i.between?(0, 100)
          values["min_score"] = values["min_score"].to_i.to_s
        end
        if values["min_value"]
          invalid!("min_value") unless values["min_value"].match?(/\A\d+(?:\.\d+)?\z/)
          values["min_value"] = BigDecimal(values["min_value"]).to_s("F")
        end
        invalid!("sector") if values["sector"] && values["sector"].length > 80
        %w[date_from date_to].each do |key|
          next unless values[key]

          begin
            invalid!(key) unless values[key].match?(/\A\d{4}-\d{2}-\d{2}\z/)
            values[key] = Date.iso8601(values[key]).iso8601
          rescue Date::Error
            invalid!(key)
          end
        end
        invalid!("date_to") if values.values_at("date_from", "date_to").all? && values["date_from"] > values["date_to"]
        values
      end

      def self.invalid!(key)
        raise InvalidParameter, "Invalid #{key} parameter"
      end
      private_class_method :invalid!
    end
  end
end
