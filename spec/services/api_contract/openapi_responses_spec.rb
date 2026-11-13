# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenapiResponses do
  include OpenapiResponses

  let(:response) { double("response", status: 200, media_type: "application/json", parsed_body: { "name" => "Example" }) }
  let(:document) do
    { "paths" => { "/profile" => { "get" => { "responses" => {
      "200" => { "content" => { "application/json" => { "schema" => {
        "type" => "object", "required" => [ "name" ], "properties" => { "name" => { "type" => "string" } }
      } } } }, "400" => { "$ref" => "#/components/responses/InvalidParameter" }
    } } } }, "components" => { "schemas" => {
      "Error" => { "type" => "object", "required" => [ "error" ], "properties" => { "error" => { "type" => "string" } } }
    }, "responses" => { "InvalidParameter" => {
      "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/Error" } } }
    } } } }
  end

  before do
    allow(YAML).to receive(:safe_load_file).with(Rails.root.join("docs/openapi.yml"), aliases: true).and_return(document)
  end

  it "validates inline JSON schemas and rejects incorrect media types and missing fields" do
    expect_documented_response(path: "/profile")
    allow(response).to receive(:parsed_body).and_return({})
    expect { expect_documented_response(path: "/profile") }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /required field missing/)
    allow(response).to receive(:media_type).and_return("text/html")
    expect { expect_documented_response(path: "/profile") }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /application\/json/)
  end

  it "uses the actual status to resolve a shared local response and its schema" do
    allow(response).to receive_messages(status: 400, parsed_body: { "error" => "Invalid parameter" })
    expect_documented_response(path: "/profile")
    allow(response).to receive(:parsed_body).and_return({ "name" => "Example" })
    expect { expect_documented_response(path: "/profile") }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /\$\.error: required field missing/)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "fails for undocumented statuses and missing local responses" do
    allow(response).to receive(:status).and_return(500)
    expect { expect_documented_response(path: "/profile") }.to raise_error(KeyError)
    allow(response).to receive(:status).and_return(400)
    document["components"]["responses"].clear
    expect { expect_documented_response(path: "/profile") }.to raise_error(KeyError)
  end

  it "rejects external and chained response references without fetching them" do
    allow(response).to receive(:status).and_return(400)
    definition = document["paths"]["/profile"]["get"]["responses"]["400"]
    definition["$ref"] = "https://example.com/response"
    expect { expect_documented_response(path: "/profile") }.to raise_error(ArgumentError, /Only direct local response/)
    definition["$ref"] = "#/components/responses/InvalidParameter"
    document["components"]["responses"]["InvalidParameter"] = definition
    expect { expect_documented_response(path: "/profile") }.to raise_error(ArgumentError, /Chained response/)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
