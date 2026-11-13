# frozen_string_literal: true

module Api
  module V1
    class ScreenerParameters
      PARAMETERS = %w[entity filters sort window_days limit cursor page].freeze

      def self.normalize(parameters)
        new(parameters).normalize
      end

      def initialize(parameters)
        @parameters = parameters
      end

      def normalize
        invalid! unless @parameters.is_a?(Hash) && (@parameters.keys - PARAMETERS).empty?
        entity = @parameters["entity"]
        invalid! unless ScreenerDefinition::FIELDS.key?(entity)
        @fields = ScreenerDefinition::FIELDS.fetch(entity)
        filters = @parameters.fetch("filters", [])
        invalid! unless filters.is_a?(Array) && filters.length <= 20
        values = { "entity" => entity, "filters" => filters.map { |filter| condition(filter) } }
        values["sort"] = @parameters.fetch("sort", "name")
        invalid! unless values["sort"].is_a?(String) && ScreenerDefinition.sorts(entity).key?(values["sort"].delete_prefix("-"))
        unless entity == "funds"
          window = @parameters.fetch("window_days", 90).to_s
          invalid! unless %w[30 90 365].include?(window)
          values["window_days"] = window
        end
        invalid! if entity == "funds" && @parameters.key?("window_days")
        pagination(values)
        values
      end

      private

      def pagination(values)
        page = @parameters.fetch("page", {})
        invalid! unless page.is_a?(Hash) && (page.keys - %w[limit cursor]).empty?
        invalid! if page.keys.any? { |key| @parameters.key?(key) }
        options = @parameters.slice("limit", "cursor").merge(page)
        limit = options.fetch("limit", 50)
        invalid! unless (limit.is_a?(Integer) || limit.is_a?(String)) && limit.to_s.match?(/\A\d{1,3}\z/) && limit.to_i.between?(1, 100)
        values["limit"] = limit.to_i.to_s
        if options.key?("cursor")
          cursor = options["cursor"]
          invalid! unless cursor.is_a?(String) && cursor.present? && cursor.bytesize <= 8192
          values["cursor"] = cursor
        end
      end

      def condition(filter)
        invalid! unless filter.is_a?(Hash) && (filter.keys - %w[field operator value]).empty?
        field, operator = filter.values_at("field", "operator")
        type = @fields[field]
        invalid! unless type && ScreenerDefinition::OPERATORS.fetch(type).include?(operator)
        value = filter["value"]
        normalized = if %w[is_null not_null].include?(operator)
          invalid! unless value.nil?
          nil
        elsif %w[in between].include?(operator)
          invalid! unless value.is_a?(Array) && value.length.between?(1, 20)
          invalid! if operator == "between" && value.length != 2
          entries = value.map { |entry| scalar(entry, type) }
          if operator == "between"
            comparison = %i[count decimal percentage].include?(type) ? entries.map { |entry| BigDecimal(entry) } : entries
            invalid! if comparison.first > comparison.last
          end
          entries
        else
          scalar(value, type)
        end
        { "field" => field, "operator" => operator, "value" => normalized }
      end

      def scalar(value, type)
        case type
        when :fund_coverage, :fund_report_type
          invalid! unless value.is_a?(String) && ScreenerDefinition::ENUM_VALUES.fetch(type).include?(value)
          value
        when :boolean
          invalid! unless value == true || value == false
          value
        when :count
          invalid! unless (value.is_a?(Integer) || value.is_a?(String)) && value.to_s.match?(/\A\d{1,20}\z/)
          invalid! if value.to_i > 9_223_372_036_854_775_807
          value.to_i.to_s
        when :decimal, :percentage
          invalid! unless value.is_a?(Numeric) || value.is_a?(String)
          text = value.to_s
          invalid! unless text.bytesize <= 128
          invalid! if value.is_a?(String) && !text.match?(/\A-?\d+(?:\.\d+)?\z/)
          number = BigDecimal(text)
          invalid! unless number.finite?
          invalid! if type == :percentage && !number.between?(0, 100)
          number.to_s("F")
        when :date
          invalid! unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          date = Date.iso8601(value, Date::GREGORIAN)
          invalid! unless date.year.positive?
          date.iso8601
        else
          invalid! unless value.is_a?(String) && value.present? && value.valid_encoding? && !value.include?("\0") && value.length <= 200
          invalid! if type == :cik && !value.match?(/\A\d{10}\z/)
          invalid! if type == :ticker && !value.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]{0,19}\z/)
          type == :ticker ? value.upcase : value
        end
      rescue ArgumentError
        invalid!
      end

      def invalid!
        raise InvalidParameter, "Invalid screener parameters"
      end
    end
  end
end
