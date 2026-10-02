# frozen_string_literal: true

require "rails_helper"

RSpec.describe PriceCheck do
  def reason(price, code)
    described_class.suspect_reason(price: price && BigDecimal(price.to_s), transaction_code: code)
  end

  it "accepts ordinary prices and absent prices" do
    expect(reason("19.13", "P")).to be_nil
    expect(reason("50000", "S")).to be_nil
    expect(reason(nil, "P")).to be_nil
  end

  it "flags a per-share price above $50,000" do
    expect(reason("50000.01", "P")).to eq("over_50k_per_share")
    expect(reason("1250000", "A")).to eq("over_50k_per_share")
  end

  it "flags a zero price only on open-market codes" do
    expect(reason("0", "P")).to eq("zero_on_open_market_code")
    expect(reason("0", "S")).to eq("zero_on_open_market_code")
    expect(reason("0", "G")).to be_nil
    expect(reason("0", "A")).to be_nil
    expect(reason("0", nil)).to be_nil
  end

  it "flags a negative price" do
    expect(reason("-1", "S")).to eq("negative")
  end
end
