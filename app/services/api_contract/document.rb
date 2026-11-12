# frozen_string_literal: true

require "yaml"
require "uri"

module ApiContract
  # Deliberately bounded checks, not a general OpenAPI/JSON Schema validator.
  class Document
    METHODS = %w[get post put patch delete head options trace].freeze
    attr_reader :errors, :operations

    def initialize(text)
      @errors, @operations = [], []
      tree = Psych.parse_stream(text)
      @errors << "Expected one YAML document" unless tree.children.size == 1
      check_duplicate_keys(tree)
      @document = YAML.safe_load(text, aliases: true)
      validate if @errors.empty?
    rescue Psych::Exception => error
      @errors << "Invalid YAML: #{error.message}"
    end

    private

    def validate
      unless @document.is_a?(Hash) && @document["openapi"] == "3.0.3" && @document["paths"].is_a?(Hash)
        @errors << "Expected an OpenAPI 3.0.3 document with a paths object"
        return
      end
      visit(@document) { |node| resolve(node["$ref"]) if node.key?("$ref") }
      operation_ids = []
      @document.fetch("paths").each do |path, item|
        unless path.is_a?(String) && path.start_with?("/") && item.is_a?(Hash)
          @errors << "Invalid path item: #{path.inspect}"
          next
        end
        item.each do |method, operation|
          next unless METHODS.include?(method)
          unless operation.is_a?(Hash)
            @errors << "Invalid operation: #{method.upcase} #{path}"
            next
          end
          validate_operation(path, item, method, operation, operation_ids)
        end
      end
      operation_ids.tally.each { |id, count| @errors << "Duplicate operationId: #{id}" if count > 1 }
      @operations = @operations.uniq.sort
    end

    def validate_operation(path, item, method, operation, ids)
      id = operation["operationId"]
      if id.is_a?(String) && !id.strip.empty?
        ids << id
      else
        @errors << "Missing operationId: #{method.upcase} #{path}"
      end
      unless operation["responses"].is_a?(Hash) && !operation["responses"].empty?
        @errors << "Missing responses: #{method.upcase} #{path}"
      end
      servers = operation.fetch("servers") { item.fetch("servers") { @document["servers"] } }
      if servers.is_a?(Array) && !servers.empty?
        servers.each do |server|
          prefix = server.is_a?(Hash) && server["url"]
          unless prefix.is_a?(String) && prefix.start_with?("/") && !prefix.start_with?("//") && !prefix.match?(/[?\#{}]/)
            @errors << "Expected a local server path for #{method.upcase} #{path}"
            next
          end
          @operations << "#{method.upcase} #{prefix.delete_suffix('/')}#{path}"
        end
      else
        @errors << "Missing servers: #{method.upcase} #{path}"
      end
      validate_parameters(path, item, operation)
    end

    def validate_parameters(path, item, operation)
      inherited = parameters(item, path)
      local = parameters(operation, path)
      # Operation parameters override path-level parameters with the same name/location.
      merged = (inherited + local).to_h { |parameter| [ [ parameter["in"], parameter["name"] ], parameter ] }
      declared = merged.values.select { |parameter| parameter["in"] == "path" }
      names = path.scan(/\{([^{}]+)\}/).flatten
      names.each do |name|
        unless declared.any? { |parameter| parameter["name"] == name && parameter["required"] == true }
          @errors << "Missing required path parameter #{name}: #{path}"
        end
      end
      declared.each do |parameter|
        @errors << "Unexpected path parameter #{parameter['name']}: #{path}" unless names.include?(parameter["name"])
      end
    end

    def parameters(owner, path)
      items = owner.fetch("parameters", [])
      unless items.is_a?(Array)
        @errors << "Invalid parameters: #{path}"
        return []
      end
      values = items.filter_map do |item|
        parameter = item.is_a?(Hash) && (item.key?("$ref") ? resolve(item["$ref"]) : item)
        if parameter.is_a?(Hash) && parameter["name"].is_a?(String) && %w[path query header cookie].include?(parameter["in"])
          parameter
        else
          @errors << "Invalid parameter: #{path}"
          nil
        end
      end
      values.group_by { |parameter| [ parameter["in"], parameter["name"] ] }.each do |key, parameters|
        @errors << "Duplicate parameter #{key.join('/')}: #{path}" if parameters.size > 1
      end
      values
    end

    def resolve(ref)
      unless ref.is_a?(String) && ref.start_with?("#/")
        @errors << "Only local references are supported: #{ref.inspect}"
        return
      end
      URI::DEFAULT_PARSER.unescape(ref.delete_prefix("#/")).split("/", -1).reduce(@document) do |node, segment|
        key = segment.gsub("~1", "/").gsub("~0", "~")
        if node.is_a?(Hash) && node.key?(key)
          node[key]
        elsif node.is_a?(Array) && key.match?(/\A(?:0|[1-9][0-9]*)\z/) && key.to_i < node.size
          node[key.to_i]
        else
          @errors << "Unresolved reference: #{ref}"
          return
        end
      end
    end

    def visit(node, ancestors = {}, &block)
      return unless node.is_a?(Hash) || node.is_a?(Array)
      if ancestors.key?(node.object_id)
        @errors << "Cyclic YAML alias is not supported"
        return
      end
      ancestors[node.object_id] = true
      if node.is_a?(Hash)
        yield node
        node.each_value { |value| visit(value, ancestors, &block) }
      else
        node.each { |value| visit(value, ancestors, &block) }
      end
      ancestors.delete(node.object_id)
    end

    def check_duplicate_keys(node)
      if node.is_a?(Psych::Nodes::Mapping)
        keys = node.children.each_slice(2).map(&:first)
        keys.group_by { |key| key.value if key.is_a?(Psych::Nodes::Scalar) }.each do |key, occurrences|
          @errors << "Duplicate YAML key #{key.inspect} at line #{occurrences.last.start_line + 1}" if occurrences.size > 1
        end
      end
      Array(node.children).each { |child| check_duplicate_keys(child) }
    end
  end
end
