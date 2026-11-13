# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::ScreenerInputRules do
  def normalize(field, value, operator: "eq", entity: "companies")
    Api::V1::ScreenerParameters.normalize({ "entity" => entity, "filters" => [ { "field" => field, "operator" => operator, "value" => value } ] })
  end

  it "enforces exact count and percentage endpoints for scalars, lists and ranges" do
    expect(normalize("purchase_count", "9223372036854775807").dig("filters", 0, "value")).to eq("9223372036854775807")
    expect(normalize("purchase_count", 0).dig("filters", 0, "value")).to eq("0")
    [ -1, "9223372036854775808", 1.5 ].each do |value|
      expect { normalize("purchase_count", value) }.to raise_error(Api::V1::InvalidParameter)
    end
    field = "reported_allocation_turnover_percent"
    expect { normalize(field, [ "0", "100" ], operator: "between", entity: "funds") }.not_to raise_error
    [ [ "eq", "-0.000001" ], [ "in", [ 0, "100.000001" ] ], [ "between", [ 100, 0 ] ] ].each do |operator, value|
      expect { normalize(field, value, operator:, entity: "funds") }.to raise_error(Api::V1::InvalidParameter)
    end
  end

  it "preserves strict whole-string formats and Gregorian calendar validation" do
    expect(normalize("ticker", "a.b-1").dig("filters", 0, "value")).to eq("A.B-1")
    %w[0001-01-01 2000-02-29 9999-12-31].each do |date|
      expect { normalize("last_filed_on", date) }.not_to raise_error
    end
    [ [ "cik", "0000000001\n" ], [ "ticker", "ACME\n" ], [ "ticker", "A" * 21 ],
      [ "last_filed_on", "1900-02-29" ], [ "last_filed_on", "0000-01-01" ],
      [ "last_filed_on", "2026-01-01\n" ], [ "purchase_value", "1.0\n" ], [ "purchase_count", "1\n" ] ].each do |field, value|
      expect { normalize(field, value) }.to raise_error(Api::V1::InvalidParameter)
    end
  end

  it "distinguishes character limits from numeric byte limits and rejects unsafe values" do
    expect { normalize("name", "é" * 200) }.not_to raise_error
    expect { normalize("name", "é" * 201) }.to raise_error(Api::V1::InvalidParameter)
    expect { normalize("purchase_value", "1" * 128) }.not_to raise_error
    [ "1" * 129, "NaN", Float::INFINITY, "1e3" ].each do |value|
      expect { normalize("purchase_value", value) }.to raise_error(Api::V1::InvalidParameter)
    end
    expect { normalize("purchase_value", 1e3) }.not_to raise_error
    [ "", " ", "a\0b" ].each do |value|
      expect { normalize("name", value) }.to raise_error(Api::V1::InvalidParameter)
    end
  end

  it "enforces published list, filter, cursor and pagination limits" do
    expect { normalize("name", Array.new(20, "Example"), operator: "in") }.not_to raise_error
    expect { normalize("name", Array.new(21, "Example"), operator: "in") }.to raise_error(Api::V1::InvalidParameter)
    expect { normalize("name", [], operator: "in") }.to raise_error(Api::V1::InvalidParameter)
    filter = { "field" => "name", "operator" => "eq", "value" => "Example" }
    options = { "entity" => "companies", "filters" => Array.new(20, filter), "limit" => 100, "cursor" => "é" * 4096 }
    expect { Api::V1::ScreenerParameters.normalize(options) }.not_to raise_error
    [ { "filters" => Array.new(21, filter) }, { "limit" => 0 }, { "limit" => 101 }, { "cursor" => "é" * 4097 } ].each do |extra|
      expect { Api::V1::ScreenerParameters.normalize(options.merge(extra)) }.to raise_error(Api::V1::InvalidParameter)
    end
  end
end
