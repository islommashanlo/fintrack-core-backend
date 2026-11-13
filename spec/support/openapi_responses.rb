# frozen_string_literal: true

module OpenapiResponses
  def expect_documented_response(path:, method: :get)
    document = YAML.safe_load_file(Rails.root.join("docs/openapi.yml"), aliases: true)
    schema = document.fetch("paths").fetch(path).fetch(method.to_s)
      .fetch("responses").fetch(response.status.to_s).fetch("content").fetch("application/json").fetch("schema")
    expect(response.media_type).to eq("application/json")
    errors = ApiContract::ResponseSchema.new(document:).errors(response.parsed_body, schema:)
    expect(errors).to be_empty, errors.join("\n")
  end
end
