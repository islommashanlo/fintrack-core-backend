# frozen_string_literal: true

module Api
  module V1
    class SavedScreenParameters
      LIST = %w[entity q sort limit cursor].freeze

      def self.write(values, create: false)
        invalid! unless values.is_a?(Hash) && values.any? && (values.keys - %w[name definition]).empty?
        invalid! if create && !%w[name definition].all? { |key| values.key?(key) }
        result = {}
        if values.key?("name")
          name = values.fetch("name")
          invalid! unless name.is_a?(String) && name.valid_encoding? && name.strip.present? && name.length <= 100 && !name.match?(/[[:cntrl:]]/)
          result[:name] = name.strip
        end
        result[:definition] = SavedScreenDefinition.normalize(values.fetch("definition")) if values.key?("definition")
        result
      end

      def self.list(values)
        invalid! if values["entity"] && !ScreenerDefinition::FIELDS.key?(values.fetch("entity"))
        invalid! if values["q"] && (values.fetch("q").length > 100 || values.fetch("q").match?(/[[:cntrl:]]/))
        values
      end

      def self.id!(value)
        invalid! unless value.is_a?(String) && value.match?(/\A[1-9]\d{0,18}\z/) && value.to_i <= 9_223_372_036_854_775_807
        value.to_i
      end

      def self.invalid!
        raise InvalidParameter, "Invalid saved screen parameters"
      end
    end
  end
end
