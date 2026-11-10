# frozen_string_literal: true

module Api
  module V1
    class ScreenerCompiler
      COMPARISONS = { "eq" => "=", "not_eq" => "<>", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=" }.freeze

      def self.call(entity:, filters:)
        # Revalidate at the compiler boundary; normalized input is not trusted SQL.
        values = ScreenerParameters.normalize({ "entity" => entity, "filters" => filters })
        values.fetch("filters").map do |filter|
          column = "activity.#{filter.fetch('field')}"
          operator, value = filter.values_at("operator", "value")
          case operator
          when "is_null" then "#{column} IS NULL"
          when "not_null" then "#{column} IS NOT NULL"
          when "in" then ApplicationRecord.sanitize_sql([ "#{column} IN (?)", value ])
          when "between" then ApplicationRecord.sanitize_sql([ "#{column} BETWEEN ? AND ?", *value ])
          when "contains", "starts_with"
            escaped = ApplicationRecord.sanitize_sql_like(value)
            pattern = operator == "contains" ? "%#{escaped}%" : "#{escaped}%"
            ApplicationRecord.sanitize_sql([ "#{column} ILIKE ?", pattern ])
          else
            ApplicationRecord.sanitize_sql([ "#{column} #{COMPARISONS.fetch(operator)} ?", value ])
          end
        end.presence&.join(" AND ") || "TRUE"
      end
    end
  end
end
