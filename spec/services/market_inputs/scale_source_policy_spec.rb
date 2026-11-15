# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketInputs::ScaleSourcePolicy do
  def settings
    { sources: [ "fixture" ], currency: "USD", measurement_basis: "issuer_equity", maximum_age_seconds: 86_400 }
  end

  it "requires explicit constraints for enabled sources and defaults to no sources" do
    expect(described_class.new.sources).to eq([])
    expect { described_class.new(sources: [ "fixture" ]) }.to raise_error(ArgumentError)
    expect { described_class.new(currency: "USD") }.to raise_error(ArgumentError)
  end

  it "binds every constraint to a stable order-independent policy digest" do
    policy = described_class.new(**settings)
    [ { currency: "EUR" }, { measurement_basis: "share_class" }, { maximum_age_seconds: 60 }, { sources: [ "another" ] } ].each do |override|
      expect(described_class.new(**settings.merge(override)).digest).not_to eq(policy.digest)
    end
    expect(described_class.new(**settings.merge(sources: %w[first second])).digest)
      .to eq(described_class.new(**settings.merge(sources: %w[second first])).digest)
  end

  it "copies and deeply freezes string policy inputs" do
    options = settings.transform_values { |value| value.is_a?(String) ? value.dup : value }
    policy = described_class.new(**options)
    options.fetch(:currency).replace("EUR")
    options.fetch(:sources).clear
    expect(policy.currency).to eq("USD")
    expect(policy.sources).to eq([ "fixture" ])
    expect { policy.measurement_basis.replace("other") }.to raise_error(FrozenError)
    expect { policy.sources.first.replace("other") }.to raise_error(FrozenError)
  end

  [ { sources: [ "fixture", "fixture" ] }, { sources: [ "bad' OR TRUE --" ] }, { sources: nil },
    { sources: 21.times.map { |i| "source_#{i}" } }, { currency: "usd" }, { currency: nil },
    { measurement_basis: " " }, { measurement_basis: "x" * 101 }, { maximum_age_seconds: 0 },
    { maximum_age_seconds: 1.5 }, { maximum_age_seconds: 2**31 } ].each do |override|
    it "rejects invalid #{override.keys.first} policy input" do
      expect { described_class.new(**settings.merge(override)) }.to raise_error(ArgumentError)
    end
  end
end
