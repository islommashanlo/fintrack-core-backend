# frozen_string_literal: true

module Api
  module V1
    class ScreenerCapabilities
      def self.call
        ScreenerDefinition::FIELDS.map do |entity, fields|
          sorts = ScreenerDefinition.sorts(entity).keys
          {
            entity:, limits: ScreenerInputRules.limits,
            fields: fields.map do |field, type|
              enum_values = ScreenerDefinition::ENUM_VALUES[type]
              { field:, type: enum_values ? "enum" : type.to_s,
                operators: ScreenerDefinition::OPERATORS.fetch(type), enum_values:, constraints: ScreenerInputRules.constraints(type) }
            end,
            sorts: sorts.flat_map { |sort| [ sort, "-#{sort}" ] }, default_sort: "name",
            window_days: entity == "funds" ? [] : ScreenerDefinition::WINDOW_DAYS,
            default_window_days: entity == "funds" ? nil : ScreenerDefinition::DEFAULT_WINDOW_DAYS
          }
        end
      end
    end
  end
end
