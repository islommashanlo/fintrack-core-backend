# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 methodology" do
  it "publishes active cluster criteria and marks proposed scoring weights as an unavailable draft" do
    get api_v1_methodology_path
    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch("data")
    expect(body.fetch("clusters")).to include("status" => "available", "window_days" => 14,
      "minimum_insiders" => 3, "time_basis" => "filed_at", "directions" => %w[purchase sale])
    score = body.fetch("score")
    expect(score).to include("status" => "unavailable", "minimum" => 0, "maximum" => 100)
    expect(score.fetch("levels").map { |level| [ level["id"], level["minimum"], level["maximum"] ] }).to eq([
      [ "normal", 0, 39 ], [ "elevated", 40, 64 ], [ "high", 65, 84 ], [ "unusual", 85, 100 ]
    ])
    proposal = score.fetch("proposal")
    expect(proposal.fetch("status")).to eq("draft")
    expect(proposal.fetch("factors").sum { |factor| factor.fetch("proposed_weight") }).to eq(100)
    expect(proposal.fetch("maximum_lateness_penalty")).to eq(15)
    expect(body.fetch("disclaimer")).to eq(FilingsIntel::DISCLAIMER)
  end

  it "rejects unknown parameters and does not expose scoring as available in activity" do
    get api_v1_methodology_path, params: { weights: "override" }
    expect(response).to have_http_status(:bad_request)
    get api_v1_activity_path
    expect(response.parsed_body.dig("meta", "scoring_available")).to be(false)
  end
end
