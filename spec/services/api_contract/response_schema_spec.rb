# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiContract::ResponseSchema do
  let(:document) { { "components" => { "schemas" => {} } } }
  subject(:validator) { described_class.new(document:) }

  def errors(value, **schema)
    validator.errors(value, schema: schema.stringify_keys)
  end

  it "checks missing required fields without confusing null or false with absence" do
    schema = { type: "object", required: %w[known nullable missing], properties: {
      "known" => { "type" => "boolean" }, "nullable" => { "type" => "string", "nullable" => true }
    } }
    expect(errors({ "known" => false, "nullable" => nil }, **schema)).to eq([ "$.missing: required field missing" ])
    expect(errors(nil, type: "string")).to include("$: expected string, got NilClass")
  end

  it "checks primitive types and rejects decimal strings as numeric values" do
    { "integer" => [ 2, 2.5 ], "number" => [ 2.5, "2.5" ], "boolean" => [ true, "true" ],
      "string" => [ "2.5", 2.5 ], "array" => [ [], {} ], "object" => [ {}, [] ] }.each do |type, (valid, invalid)|
      expect(errors(valid, type:)).to be_empty
      expect(errors(invalid, type:)).not_to be_empty
    end
    expect(errors(Float::INFINITY, type: "number")).not_to be_empty
  end

  it "checks nested arrays, enum membership and bounds with useful response paths" do
    schema = { type: "array", minItems: 1, maxItems: 2, items: {
      "type" => "object", "properties" => { "rank" => { "type" => "integer", "minimum" => 1, "maximum" => 3 },
        "direction" => { "type" => "string", "enum" => %w[purchase sale] } }
    } }
    expect(errors([], **schema)).to eq([ "$: below minItems 1" ])
    expect(errors([ { "rank" => 0, "direction" => "other" } ], **schema)).to include(
      "$[0].rank: below minimum 1", "$[0].direction: value is outside enum")
    expect(errors([ { "rank" => 4 }, {}, {} ], **schema)).to include("$: above maxItems 2", "$[0].rank: above maximum 3")
  end

  it "validates signed int64 boundaries without accepting overflow, strings or floats" do
    [ -(2**63), 0, 2**63 - 1 ].each do |value|
      expect(errors(value, type: "integer", format: "int64")).to be_empty
    end
    [ -(2**63) - 1, 2**63 ].each do |value|
      expect(errors(value, type: "integer", format: "int64")).to eq([ "$: outside int64 range" ])
    end
    [ "1", 1.0 ].each do |value|
      expect(errors(value, type: "integer", format: "int64")).not_to be_empty
    end
    expect(errors([], type: "array", format: "int64").join).to include("int64 format requires integer type")
  end

  it "checks unique items by JSON value, including nested objects and equivalent numbers" do
    expect(errors([ "holdings", "notice" ], type: "array", uniqueItems: true)).to be_empty
    expect(errors([ "holdings", "holdings" ], type: "array", uniqueItems: true)).to eq([ "$: duplicate array items" ])
    expect(errors([ { "a" => [ 1 ], "b" => false }, { "b" => false, "a" => [ 1.0 ] } ],
      type: "array", uniqueItems: true)).to eq([ "$: duplicate array items" ])
    expect(errors([ 1, 1.0 ], type: "array", uniqueItems: true)).not_to be_empty
    expect(errors([ 1, 1 ], type: "array", uniqueItems: false)).to be_empty
  end

  it "resolves shared schemas and checks every allOf branch" do
    document["components"]["schemas"]["Identity"] = { "type" => "object", "required" => [ "cik" ],
      "properties" => { "cik" => { "type" => "string", "pattern" => "^[0-9]{10}$" } } }
    schema = { allOf: [ { "$ref" => "#/components/schemas/Identity" }, { "required" => [ "name" ] } ] }
    expect(errors({ "cik" => "bad" }, **schema)).to include("$.cik: does not match pattern", "$.name: required field missing")
    expect(errors({ "cik" => "0000000001", "name" => "Example" }, **schema)).to be_empty
  end

  it "validates exactly one matching oneOf branch, including references" do
    document["components"]["schemas"]["Name"] = { "type" => "string" }
    schema = { oneOf: [ { "$ref" => "#/components/schemas/Name" }, { "type" => "integer" } ] }
    expect(errors("Example", **schema)).to be_empty
    expect(errors(10, **schema)).to be_empty
    expect(errors(false, **schema)).to eq([ "$: expected exactly one oneOf match, got 0" ])
    expect(errors(1, oneOf: [ { "type" => "number" }, { "type" => "integer" } ])).to eq([ "$: expected exactly one oneOf match, got 2" ])
    expect(errors([], type: "array", items: { "oneOf" => [ { "not" => {} } ] }).join).to include("unsupported keyword not")
  end

  it "validates string length and supported formats without network access" do
    expect(errors("abc", type: "string", minLength: 4)).not_to be_empty
    expect(errors("abc", type: "string", maxLength: 2)).not_to be_empty
    { "date" => [ "2026-11-12", "2026-02-30" ],
      "date-time" => [ "2026-11-12T12:00:00.000Z", "2026-11-12T12:00:00" ],
      "uri" => [ "https://example.com/filing", "/relative" ] }.each do |format, (valid, invalid)|
      expect(errors(valid, type: "string", format:)).to be_empty
      expect(errors(invalid, type: "string", format:)).to include("$: invalid #{format}")
    end
    expect(errors("2026-11-12T24:00:00Z", type: "string", format: "date-time")).not_to be_empty
    expect(errors("2026-02-30T12:00:00Z", type: "string", format: "date-time")).not_to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "checks explicit additional-property rules while leaving undeclared fields allowed by default" do
    expect(errors({ "extra" => 1 }, type: "object")).to be_empty
    expect(errors({ "extra" => 1 }, type: "object", additionalProperties: false)).to eq([ "$.extra: unexpected field" ])
    expect(errors({ "P" => "1" }, type: "object", additionalProperties: { "type" => "integer" })).not_to be_empty
  end

  it "rejects unsupported schema keywords and formats even on empty or absent data" do
    expect(errors([], type: "array", items: { "not" => {} }).join).to include("unsupported keyword not")
    expect(errors({}, properties: { "absent" => { "format" => "email" } }).join).to include("unsupported format email")
    expect(errors(nil, type: "null").join).to include("unsupported type null")
    expect(errors({}, properties: { "absent" => { "pattern" => "[" } })).not_to be_empty
  end

  it "rejects unresolved, external and recursive references and validation siblings" do
    expect(errors({}, "$ref" => "https://example.com/schema").join).to include("Only direct local")
    expect(errors({}, "$ref" => "#/components/schemas/Missing")).not_to be_empty
    document["components"]["schemas"]["Loop"] = { "$ref" => "#/components/schemas/Loop" }
    expect(errors({}, "$ref" => "#/components/schemas/Loop").join).to include("recursive schemas are unsupported")
    document["components"]["schemas"]["Name"] = { "type" => "string" }
    expect(errors("ok", "$ref" => "#/components/schemas/Name", "nullable" => true).join).to include("validation siblings")
    expect(errors("ok", "$ref" => "#/components/schemas/Name", "description" => "Annotation")).to be_empty
  end

  it "resets diagnostics between calls" do
    expect(errors("bad", type: "integer")).not_to be_empty
    expect(errors(1, type: "integer")).to be_empty
  end
  it "accepts one or more anyOf matches and still inspects every branch" do
    schema = { anyOf: [ { "type" => "integer" }, { "type" => "number" } ] }
    expect(errors(1, **schema)).to be_empty
    expect(errors(1.5, **schema)).to be_empty
    expect(errors("1", **schema)).to eq([ "$: expected at least one anyOf match" ])
    document["components"]["schemas"]["Object"] = { "type" => "object" }
    expect(errors({}, anyOf: [ { "$ref" => "#/components/schemas/Object" }, { "type" => "string" } ])).to be_empty
    expect(errors({}, anyOf: [ { "type" => "object" }, { "not" => {} } ]).join).to include("unsupported keyword not")
  end
end
