# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form13fValueNormalizer do
  it "normalizes whole-dollar values while retaining the reported value" do
    result = described_class.normalize(value_reported: BigDecimal("1602900"), value_unit: "whole_dollars")

    expect(result).to have_attributes(
      value_reported: BigDecimal("1602900"), value_unit: "whole_dollars", value_usd: BigDecimal("1602900"),
      suspect: false, suspect_reason: nil
    )
  end

  it "converts values reported in thousands" do
    result = described_class.normalize(value_reported: BigDecimal("78819"), value_unit: "thousands")

    expect(result.value_reported).to eq(BigDecimal("78819"))
    expect(result.value_usd).to eq(BigDecimal("78819000"))
    expect(result.suspect).to be(false)
  end

  it "flags an unresolved unit without inventing a dollar value" do
    result = described_class.normalize(value_reported: "78819", value_unit: "unresolved")

    expect(result).to have_attributes(
      value_reported: BigDecimal("78819"), value_unit: "unresolved", value_usd: nil,
      suspect: true, suspect_reason: "unknown_value_unit"
    )
  end

  it "accepts the common dollar unit alias" do
    expect(described_class.normalize(value_reported: 12, value_unit: "dollars").value_unit).to eq("whole_dollars")
  end
end
