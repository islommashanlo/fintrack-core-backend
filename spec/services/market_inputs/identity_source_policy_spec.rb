# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketInputs::IdentitySourcePolicy do
  it "defaults to no sources and produces order-independent policy identities" do
    expect(described_class.new.sources).to eq([])
    expect(described_class.new(sources: %w[first second]).digest).to eq(described_class.new(sources: %w[second first]).digest)
    expect(described_class.new(sources: [ "first" ]).digest).not_to eq(described_class.new(sources: [ "second" ]).digest)
  end

  it "takes a deeply frozen copy without modifying caller-owned configuration" do
    source = +"fixture"
    sources = [ source ]
    policy = described_class.new(sources:)
    source.replace("changed")
    sources.clear
    expect(policy.sources).to eq([ "fixture" ])
    expect { policy.sources << "other" }.to raise_error(FrozenError)
    expect { policy.sources.first.replace("other") }.to raise_error(FrozenError)
  end

  [ nil, "fixture", [ "fixture", "fixture" ], [ "x' OR TRUE --" ], [ "fixture\n" ], [ nil ],
    21.times.map { |i| "source_#{i}" } ].each do |value|
    it "rejects invalid source policy #{value.inspect}" do
      expect { described_class.new(sources: value) }.to raise_error(ArgumentError)
    end
  end
end
