# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::ScreenerParameters do
  it "normalizes a typed screen and nested cursor page without losing decimal precision" do
    result = described_class.normalize({ "entity" => "companies", "window_days" => 30,
      "filters" => [ { "field" => "purchase_value", "operator" => "gte", "value" => "9223372036854775808000.000001" } ],
      "page" => { "limit" => 2, "cursor" => "signed" } })
    expect(result).to include("entity" => "companies", "window_days" => "30", "limit" => "2", "cursor" => "signed", "sort" => "name")
    expect(result.fetch("filters").sole.fetch("value")).to eq("9223372036854775808000.000001")
  end

  [ { "entity" => "unknown" }, { "entity" => [] }, { "filters" => {} }, { "filters" => nil },
    { "filters" => Array.new(21, {}) }, { "filters" => [ "raw SQL" ] }, { "sort" => "name; SELECT 1" },
    { "sort" => [ "name" ] }, { "window_days" => 0 }, { "window_days" => 30.0 },
    { "page" => 2 }, { "page" => { "offset" => 4 } }, { "page" => { "limit" => 1 }, "limit" => 1 },
    { "limit" => 0 }, { "limit" => 101 }, { "limit" => true }, { "limit" => 1.5 }, { "cursor" => "x" * 8193 },
    { "offset" => 3 }, { "plan" => "pro" }, { "user_id" => 1 },
    { "filters" => [ { "field" => "name", "operator" => "contains", "value" => "unsafe\0string" } ] }
  ].each_with_index do |options, index|
    it "rejects malformed request shape #{index + 1}" do
      expect { described_class.normalize({ "entity" => "companies" }.merge(options)) }.to raise_error(Api::V1::InvalidParameter)
    end
  end

  it "does not accept transaction windows or unsupported metrics for fund screens" do
    expect { described_class.normalize({ "entity" => "funds", "window_days" => 90 }) }.to raise_error(Api::V1::InvalidParameter)
    %w[aum turnover sector score].each do |field|
      expect do
        described_class.normalize({ "entity" => "funds", "filters" => [ { "field" => field, "operator" => "gte", "value" => 1 } ] })
      end.to raise_error(Api::V1::InvalidParameter)
    end
  end
end
