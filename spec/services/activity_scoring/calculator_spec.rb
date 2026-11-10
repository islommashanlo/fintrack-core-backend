# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActivityScoring::Calculator do
  let(:definition) { ActivityMethodology.definition }
  let(:factors) do
    definition.fetch("score").fetch("proposal").fetch("factors").to_h do |factor|
      [ factor.fetch("id"), { status: "available", value: 1, reason: "Measured #{factor.fetch('id')}.", inputs: {} } ]
    end
  end
  let(:lateness) { { status: "available", value: 0, reason: "Reported transaction and filing dates match.", inputs: {} } }

  def calculate
    described_class.new(definition:).call(factors:, lateness:)
  end

  def activate_test_definition
    definition.fetch("score")["status"] = "available"
  end

  it "keeps a complete calculation unpublished while the methodology is a draft" do
    expect(calculate).to include(status: "draft", score: nil, level: nil, reasons: [],
      coverage: { available_weight: 100, required_weight: 100, missing_factors: [], lateness_available: true })
    expect(calculate.fetch(:factors).sum { |factor| factor.fetch(:points) }).to eq(100)
    expect(ActivityMethodology.definition.dig("score", "status")).to eq("unavailable")
  end

  it "keeps missing factors null without zero-filling, rescaling or returning a partial score" do
    activate_test_definition
    factors["issuer_scale_and_liquidity"] = { status: "unavailable", reason: "No stored inputs.",
      unavailable_reason: "market_inputs_unavailable", inputs: {} }
    result = calculate
    expect(result).to include(status: "incomplete", score: nil, level: nil, reasons: [])
    expect(result.fetch(:coverage)).to include(available_weight: 75, required_weight: 100,
      missing_factors: [ "issuer_scale_and_liquidity" ])
    expect(result.fetch(:factors).find { |factor| factor[:id] == "issuer_scale_and_liquidity" })
      .to include(value: nil, points: nil, weight: 25)
    expect(result.fetch(:factors).find { |factor| factor[:id] == "own_history" }).to include(points: 25, weight: 25)
  end

  it "requires a measured staleness penalty, including a measured zero" do
    lateness.replace(status: "unavailable", reason: "Missing date.", inputs: {})
    expect(calculate).to include(status: "incomplete", score: nil)
    expect(calculate.fetch(:coverage)).to include(available_weight: 100, missing_factors: [ "lateness" ], lateness_available: false)
  end

  { 0 => "normal", 39 => "normal", 40 => "elevated", 64 => "elevated", 65 => "high", 84 => "high", 85 => "unusual", 100 => "unusual" }.each do |points, level|
    it "uses the configured level boundary at #{points}" do
      activate_test_definition
      factors.each_value { |factor| factor[:value] = BigDecimal(points.to_s) / 100 }
      result = calculate
      expect(result).to include(status: "available", score: points, level:)
      expect(result.fetch(:reasons).length).to be_between(2, 4)
    end
  end

  it "subtracts the penalty, rounds once and clamps the final score" do
    activate_test_definition
    lateness[:value] = BigDecimal("0.1")
    expect(calculate).to include(score: 99, level: "unusual")
    expect(calculate.fetch(:factors).last).to include(id: "lateness", points: BigDecimal("-1.5"))
    factors.each_value { |factor| factor[:value] = 0 }
    lateness[:value] = 1
    expect(calculate).to include(score: 0, level: "normal")
  end

  [ -0.1, 1.1, "NaN", "Infinity", nil, "invalid" ].each do |value|
    it "rejects an invalid measured value #{value.inspect}" do
      factors.fetch("own_history")[:value] = value
      expect { calculate }.to raise_error(ArgumentError)
    end
  end

  it "rejects values attached to unavailable factors and unknown factor IDs" do
    factors.fetch("own_history")[:status] = "unavailable"
    expect { calculate }.to raise_error(ArgumentError, /Unavailable/)
    factors["unknown"] = factors.fetch("own_history")
    expect { calculate }.to raise_error(ArgumentError, /Unknown/)
  end

  it "rejects duplicate factor IDs and an inconsistent weight total" do
    definition.fetch("score").fetch("proposal").fetch("factors").first["proposed_weight"] = 1
    expect { calculate }.to raise_error(ArgumentError, /weights/)
    definition.fetch("score").fetch("proposal").fetch("factors").first["proposed_weight"] = 25
    definition.fetch("score").fetch("proposal").fetch("factors").last["id"] = "own_history"
    expect { calculate }.to raise_error(ArgumentError, /weights/)
  end
end
