# frozen_string_literal: true

require "date"
require "time"
require "uri"

module ApiContract
  # An explicit OpenAPI subset for local response tests; never fetches references.
  class ResponseSchema
    ANNOTATIONS = %w[title description example default deprecated readOnly writeOnly].freeze
    RULES = %w[$ref type nullable properties required items additionalProperties allOf oneOf anyOf enum minimum maximum minItems maxItems uniqueItems minLength maxLength pattern format].freeze
    TYPES = %w[object array string integer number boolean].freeze
    FORMATS = %w[date date-time uri int64].freeze

    def initialize(document:)
      @document = document
    end

    def errors(value, schema:)
      @errors = []
      inspect_schema(schema, "schema", [])
      validate(value, schema, "$") if @errors.empty?
      @errors
    end

    private

    def reference(schema)
      ref = schema.fetch("$ref")
      unless ref.is_a?(String) && ref.match?(%r{\A#/components/schemas/[^/~]+\z})
        raise ArgumentError, "Only direct local component schema references are supported"
      end
      @document.fetch("components").fetch("schemas").fetch(ref.split("/").last)
    end

    def inspect_schema(schema, path, ancestors)
      unless schema.is_a?(Hash)
        @errors << "#{path}: expected a schema object"
        return
      end
      if ancestors.include?(schema.object_id)
        @errors << "#{path}: recursive schemas are unsupported"
        return
      end
      ancestors = ancestors + [ schema.object_id ]
      (schema.keys - RULES - ANNOTATIONS).each { |key| @errors << "#{path}: unsupported keyword #{key}" }
      if schema.key?("$ref")
        siblings = schema.keys - ANNOTATIONS - [ "$ref" ]
        @errors << "#{path}: validation siblings of $ref are unsupported" if siblings.any?
        inspect_schema(reference(schema), "#{path}.$ref", ancestors)
        return
      end
      @errors << "#{path}: unsupported type #{schema['type']}" if schema.key?("type") && !TYPES.include?(schema["type"])
      @errors << "#{path}: unsupported format #{schema['format']}" if schema.key?("format") && !FORMATS.include?(schema["format"])
      if schema["format"] == "int64" && schema["type"] != "integer"
        @errors << "#{path}: int64 format requires integer type"
      end
      Regexp.new(schema.fetch("pattern")) if schema.key?("pattern")
      schema.fetch("properties", {}).each { |key, child| inspect_schema(child, "#{path}.#{key}", ancestors) }
      %w[allOf oneOf anyOf].each do |composition|
        schema.fetch(composition, []).each_with_index { |child, i| inspect_schema(child, "#{path}.#{composition}[#{i}]", ancestors) }
      end
      inspect_schema(schema["items"], "#{path}.items", ancestors) if schema.key?("items")
      additional = schema["additionalProperties"]
      inspect_schema(additional, "#{path}.additionalProperties", ancestors) if additional.is_a?(Hash)
    rescue KeyError, ArgumentError, RegexpError => error
      @errors << "#{path}: #{error.message}"
    end

    def validate(value, schema, path)
      return validate(value, reference(schema), path) if schema.key?("$ref")
      return if value.nil? && schema["nullable"] == true

      schema.fetch("allOf", []).each { |child| validate(value, child, path) }
      if schema.key?("oneOf")
        matches = schema.fetch("oneOf").count { |child| self.class.new(document: @document).errors(value, schema: child).empty? }
        @errors << "#{path}: expected exactly one oneOf match, got #{matches}" unless matches == 1
      end
      if schema.key?("anyOf")
        matches = schema.fetch("anyOf").any? { |child| self.class.new(document: @document).errors(value, schema: child).empty? }
        @errors << "#{path}: expected at least one anyOf match" unless matches
      end
      if schema.key?("type") && !matches_type?(value, schema["type"])
        @errors << "#{path}: expected #{schema['type']}, got #{value.class}"
        return
      end
      @errors << "#{path}: value is outside enum" if schema.key?("enum") && !schema["enum"].include?(value)
      case value
      when Hash then validate_object(value, schema, path)
      when Array
        bounds(value.length, schema, path, "minItems", "maxItems")
        if schema["uniqueItems"] == true && value.combination(2).any? { |left, right| left == right }
          @errors << "#{path}: duplicate array items"
        end
        value.each_with_index { |item, i| validate(item, schema["items"], "#{path}[#{i}]") } if schema.key?("items")
      when String
        bounds(value.length, schema, path, "minLength", "maxLength")
        @errors << "#{path}: does not match pattern" if schema.key?("pattern") && !Regexp.new(schema["pattern"]).match?(value)
        @errors << "#{path}: invalid #{schema['format']}" if schema.key?("format") && !valid_format?(value, schema["format"])
      when Numeric
        bounds(value, schema, path, "minimum", "maximum")
        if schema["format"] == "int64" && !value.between?(-(2**63), 2**63 - 1)
          @errors << "#{path}: outside int64 range"
        end
      end
    end

    def validate_object(value, schema, path)
      schema.fetch("required", []).each { |key| @errors << "#{path}.#{key}: required field missing" unless value.key?(key) }
      properties = schema.fetch("properties", {})
      value.each do |key, item|
        if properties.key?(key)
          validate(item, properties[key], "#{path}.#{key}")
        elsif schema["additionalProperties"] == false
          @errors << "#{path}.#{key}: unexpected field"
        elsif schema["additionalProperties"].is_a?(Hash)
          validate(item, schema["additionalProperties"], "#{path}.#{key}")
        end
      end
    end

    def matches_type?(value, type)
      case type
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
      when "boolean" then value == true || value == false
      end
    end

    def bounds(value, schema, path, minimum, maximum)
      @errors << "#{path}: below #{minimum} #{schema[minimum]}" if schema.key?(minimum) && value < schema[minimum]
      @errors << "#{path}: above #{maximum} #{schema[maximum]}" if schema.key?(maximum) && value > schema[maximum]
    end

    def valid_format?(value, format)
      case format
      when "date"
        value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value)
      when "date-time"
        value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/) &&
          value[11, 2].to_i < 24 && value[14, 2].to_i < 60 && value[17, 2].to_i <= 60 &&
          Date.iso8601(value[0, 10]) && Time.iso8601(value)
      when "uri"
        uri = URI.parse(value)
        uri.absolute? && (!%w[http https].include?(uri.scheme) || (uri.host && !uri.host.empty?))
      end
    rescue ArgumentError, URI::InvalidURIError
      false
    end
  end
end
