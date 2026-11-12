# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiContract::Document do
  def base
    {
      "openapi" => "3.0.3", "servers" => [ { "url" => "/api/v1" } ],
      "paths" => { "/things/{id}" => {
        "parameters" => [ { "name" => "id", "in" => "path", "required" => true } ],
        "get" => { "operationId" => "getThing", "responses" => { "200" => { "description" => "Stored thing" } } }
      } }
    }
  end

  def check(document = base)
    described_class.new(YAML.dump(document))
  end

  it "normalizes root, path and operation server overrides without changing path parameter names" do
    document = base
    document["paths"]["/things/{id}"]["servers"] = [ { "url" => "/" } ]
    document["paths"]["/things/{id}"]["post"] = {
      "operationId" => "createThing", "servers" => [ { "url" => "/alternate/" } ], "responses" => { "201" => {} }
    }
    result = check(document)
    expect(result.errors).to eq([])
    expect(result.operations).to eq([ "GET /things/{id}", "POST /alternate/things/{id}" ])
  end

  it "resolves component parameters and JSON pointers with escaped keys and array indices" do
    document = base
    document["components"] = { "parameters" => { "ThingId" => document["paths"]["/things/{id}"]["parameters"].sole },
      "schemas" => { "a/b~c" => { "allOf" => [ { "type" => "string" } ] } } }
    document["paths"]["/things/{id}"]["parameters"] = [ { "$ref" => "#/components/parameters/ThingId" } ]
    document["paths"]["/things/{id}"]["get"]["responses"]["200"]["schema"] = { "$ref" => "#/components/schemas/a~1b~0c/allOf/0" }
    expect(check(document).errors).to eq([])
  end

  it "rejects unresolved and external references without fetching anything" do
    [ "#/components/schemas/Missing", "https://example.com/schema.yml", 123 ].each do |reference|
      document = base
      document["components"] = { "schemas" => { "Thing" => { "$ref" => reference } } }
      expect(check(document).errors.join).to match(/reference/)
    end
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "requires unique nonblank operation IDs and response definitions" do
    document = base
    document["paths"]["/other"] = { "post" => { "operationId" => "getThing" } }
    expect(check(document).errors).to include("Duplicate operationId: getThing", "Missing responses: POST /other")
    document["paths"]["/other"]["post"]["operationId"] = " "
    expect(check(document).errors).to include("Missing operationId: POST /other")
  end

  it "requires path parameters and rejects undeclared placeholders, extras and duplicates" do
    document = base
    parameters = document["paths"]["/things/{id}"]["parameters"]
    parameters.first["required"] = false
    parameters << { "name" => "extra", "in" => "path", "required" => true }
    parameters << parameters.last.dup
    expect(check(document).errors).to include("Missing required path parameter id: /things/{id}",
      "Unexpected path parameter extra: /things/{id}", "Duplicate parameter path/extra: /things/{id}")
  end

  it "allows operation parameter overrides while checking their required flag" do
    document = base
    operation = document["paths"]["/things/{id}"]["get"]
    operation["parameters"] = [ { "name" => "id", "in" => "path", "required" => true } ]
    expect(check(document).errors).to eq([])
    operation["parameters"].first["required"] = false
    expect(check(document).errors).to include("Missing required path parameter id: /things/{id}")
  end

  it "reports malformed parameter lists and invalid local server paths" do
    [ nil, "query" ].each do |parameters|
      document = base
      document["paths"]["/things/{id}"]["parameters"] = parameters
      expect(check(document).errors).to include("Invalid parameters: /things/{id}")
    end
    [ "https://example.com", "//example.com", "/api/{version}", "/api?test", "/api#fragment" ].each do |url|
      document = base.merge("servers" => [ { "url" => url } ])
      expect(check(document).errors.join).to include("Expected a local server path")
    end
  end

  it "detects duplicate YAML keys before loading can overwrite an operation or schema" do
    text = YAML.dump(base).sub("openapi: 3.0.3", "openapi: 3.0.3\nopenapi: 3.0.3")
    expect(described_class.new(text).errors.join).to include("Duplicate YAML key", "line 3")
  end

  it "accepts shared YAML aliases but rejects cyclic aliases and multiple documents" do
    document = base
    shared = { "type" => "string" }
    document["components"] = { "schemas" => { "First" => shared, "Second" => shared } }
    expect(check(document).errors).to eq([])
    shared["self"] = shared
    expect(check(document).errors).to include("Cyclic YAML alias is not supported")
    expect(described_class.new(YAML.dump(base) + "---\nextra: true\n").errors).to include("Expected one YAML document")
  end

  it "reports malformed YAML and unsupported document roots without crashing" do
    expect(described_class.new("paths: [").errors.join).to include("Invalid YAML")
    [ nil, [], { "openapi" => "3.1.0", "paths" => {} } ].each do |document|
      expect(check(document).errors.join).to include("Expected an OpenAPI 3.0.3 document")
    end
  end
end
