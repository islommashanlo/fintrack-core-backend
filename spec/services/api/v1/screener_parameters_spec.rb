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

  it "normalizes fund percentage conditions numerically for bounds, lists and nulls" do
    result = described_class.normalize({ "entity" => "funds", "sort" => "-reported_allocation_turnover_percent", "filters" => [
      { "field" => "reported_allocation_turnover_percent", "operator" => "between", "value" => [ "9.000000000001", "100" ] },
      { "field" => "reported_allocation_turnover_percent", "operator" => "in", "value" => [ 0, "25.25", 100 ] },
      { "field" => "reported_allocation_turnover_percent", "operator" => "not_null" }
    ] })
    expect(result.fetch("filters").map { |row| row["value"] }).to eq([ [ "9.000000000001", "100.0" ], [ "0.0", "25.25", "100.0" ], nil ])
  end

  it "rejects invalid percentages at every value boundary and for other entities" do
    field = "reported_allocation_turnover_percent"
    [ [ "eq", -1 ], [ "gt", "100.000000000001" ], [ "eq", "NaN" ], [ "eq", Float::INFINITY ],
      [ "in", [ 0, 101 ] ], [ "between", [ 50, 49 ] ], [ "contains", "50" ], [ "is_null", false ] ].each do |operator, value|
      expect { described_class.normalize({ "entity" => "funds", "filters" => [ { "field" => field, "operator" => operator, "value" => value } ] }) }
        .to raise_error(Api::V1::InvalidParameter)
    end
    %w[companies insiders].each do |entity|
      expect { described_class.normalize({ "entity" => entity, "sort" => field }) }.to raise_error(Api::V1::InvalidParameter)
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

  it "accepts only fund coverage and report membership enums and scalar coverage sorts" do
    filters = [
      { "field" => "coverage", "operator" => "in", "value" => %w[complete history_restricted] },
      { "field" => "report_type", "operator" => "not_eq", "value" => "notice" }
    ]
    expect(described_class.normalize({ "entity" => "funds", "filters" => filters, "sort" => "-coverage" }))
      .to include("filters" => filters, "sort" => "-coverage")
    [
      { "field" => "coverage", "operator" => "eq", "value" => "COMPLETE" },
      { "field" => "coverage", "operator" => "contains", "value" => "complete" },
      { "field" => "report_type", "operator" => "in", "value" => [ "holdings", "unknown" ] },
      { "field" => "report_type", "operator" => "eq", "value" => "holdings' OR TRUE --" },
      { "field" => "report_type", "operator" => "is_null" }
    ].each do |filter|
      expect { described_class.normalize({ "entity" => "funds", "filters" => [ filter ] }) }.to raise_error(Api::V1::InvalidParameter)
    end
    expect { described_class.normalize({ "entity" => "funds", "sort" => "report_type" }) }.to raise_error(Api::V1::InvalidParameter)
    %w[companies insiders].each do |entity|
      expect { described_class.normalize({ "entity" => entity, "filters" => filters }) }.to raise_error(Api::V1::InvalidParameter)
    end
  end
end
