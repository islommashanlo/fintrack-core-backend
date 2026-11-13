# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::ScreenerCompiler do
  it "compiles numeric, text and null predicates with AND and literal quoting" do
    sql = described_class.call(entity: "companies", filters: [
      { "field" => "purchase_count", "operator" => "gte", "value" => 3 },
      { "field" => "name", "operator" => "contains", "value" => "O'Brien_%" },
      { "field" => "purchase_value", "operator" => "not_null" }
    ])
    expect(sql).to include("activity.purchase_count >= '3'", "O''Brien", "AND activity.purchase_value IS NOT NULL")
    expect(sql).to include("\\_", "\\%")
  end

  it "revalidates and quotes the fund percentage whitelist at the SQL boundary" do
    field = "reported_allocation_turnover_percent"
    sql = described_class.call(entity: "funds", filters: [ { "field" => field, "operator" => "between", "value" => [ "9", "100" ] },
      { "field" => field, "operator" => "not_null" } ])
    expect(sql).to include("activity.#{field} BETWEEN '9.0' AND '100.0'", "activity.#{field} IS NOT NULL")
    expect { described_class.call(entity: "funds", filters: [ { "field" => field, "operator" => "gte", "value" => "101 OR 1=1" } ]) }
      .to raise_error(Api::V1::InvalidParameter)
  end

  it "returns TRUE for an empty condition list" do
    expect(described_class.call(entity: "funds", filters: [])).to eq("TRUE")
  end

  invalid_conditions = [
    { "field" => "name); DROP TABLE users; --", "operator" => "eq", "value" => "x" },
    { "field" => "name", "operator" => "eq; SELECT 1", "value" => "x" },
    { "field" => "score", "operator" => "gte", "value" => 1 },
    { "field" => "sector", "operator" => "eq", "value" => "Technology" },
    { "field" => "purchase_count", "operator" => "eq", "value" => "0 OR 1=1" },
    { "field" => "purchase_count", "operator" => "eq", "value" => 1.1 },
    { "field" => "purchase_count", "operator" => "eq", "value" => "9223372036854775808" },
    { "field" => "purchase_value", "operator" => "gte", "value" => "NaN" },
    { "field" => "purchase_value", "operator" => "eq", "value" => "Infinity" },
    { "field" => "purchase_value", "operator" => "between", "value" => [ 5, 1 ] },
    { "field" => "name", "operator" => "between", "value" => %w[a b] },
    { "field" => "name", "operator" => "contains", "value" => { "sql" => "SELECT 1" } },
    { "field" => "name", "operator" => "in", "value" => [] },
    { "field" => "name", "operator" => "in", "value" => Array.new(21, "x") },
    { "field" => "name", "operator" => "is_null", "value" => false },
    { "field" => "last_filed_on", "operator" => "eq", "value" => "2026-02-30" },
    { "field" => "last_filed_on", "operator" => "eq", "value" => "0000-01-01" },
    { "field" => "last_filed_on", "operator" => "eq", "value" => "0100-02-29" },
    { "field" => "cik", "operator" => "eq", "value" => 123 },
    { "field" => "ticker", "operator" => "eq", "value" => "%" },
    { "field" => "name", "operator" => "eq", "value" => "x", "raw_sql" => "TRUE" }
  ]
  invalid_conditions.each_with_index do |condition, index|
    it "rejects invalid or unrecognized condition #{index + 1} at the compiler boundary" do
      expect { described_class.call(entity: "companies", filters: [ condition ]) }.to raise_error(Api::V1::InvalidParameter)
    end
  end
end
