# frozen_string_literal: true

module OpenapiResponses
  def expect_documented_response(path:, method: :get)
    document = YAML.safe_load_file(Rails.root.join("docs/openapi.yml"), aliases: true)
    definition = document.fetch("paths").fetch(path).fetch(method.to_s)
      .fetch("responses").fetch(response.status.to_s)
    if definition.key?("$ref")
      ref = definition.fetch("$ref")
      unless ref.is_a?(String) && ref.match?(%r{\A#/components/responses/[^/~]+\z})
        raise ArgumentError, "Only direct local response references are supported"
      end
      definition = document.fetch("components").fetch("responses").fetch(ref.split("/").last)
      raise ArgumentError, "Chained response references are unsupported" if definition.key?("$ref")
    end
    schema = definition.fetch("content").fetch("application/json").fetch("schema")
    expect(response.media_type).to eq("application/json")
    errors = ApiContract::ResponseSchema.new(document:).errors(response.parsed_body, schema:)
    expect(errors).to be_empty, errors.join("\n")
  end
end
