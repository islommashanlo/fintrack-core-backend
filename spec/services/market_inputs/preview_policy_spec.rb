# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketInputs::PreviewPolicy do
  it "loads only the fixed checked-in policy and defaults to no enabled sources" do
    policy = described_class.load
    expect(policy.identity_policy.sources).to eq([])
    expect(policy.scale_policy.sources).to eq([])
  end

  [ nil, {}, { "identity" => { "sources" => [] }, "scale" => {}, "extra" => true },
    { "identity" => { "sources" => [ "bad source" ] }, "scale" => { "sources" => [], "currency" => nil, "measurement_basis" => nil, "maximum_age_seconds" => nil } } ].each do |definition|
    it "fails visibly on invalid operator configuration #{definition.inspect}" do
      allow(YAML).to receive(:safe_load_file).with(Rails.root.join("config/market_input_preview.yml")).and_return(definition)
      expect { described_class.load }.to raise_error(ArgumentError)
    end
  end
end
