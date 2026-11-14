# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 methodology" do
  include OpenapiResponses
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
    expect(score.fetch("insider_factors")).to include("status" => "draft", "detail_diagnostics" => "available",
      "history_days" => 365, "minimum_history" => 5, "staleness_full_penalty_days" => 30)
    expect(score.fetch("institutional_factors")).to include("status" => "draft", "detail_diagnostics" => "available",
      "history_quarters" => 8, "minimum_history" => 5, "participation_full_count" => 3, "staleness_full_penalty_days" => 90)
    expect(body.fetch("disclaimer")).to eq(FilingsIntel::DISCLAIMER)
  end

  it "rejects unknown parameters and does not expose scoring as available in activity" do
    get api_v1_methodology_path, params: { weights: "override" }
    expect(response).to have_http_status(:bad_request)
    get api_v1_activity_path
    expect(response.parsed_body.dig("meta", "scoring_available")).to be(false)
  end
  it "distinguishes stored OHLCV capability from unevaluated score inputs" do
    expect(PriceDaily).not_to receive(:where)
    expect(PriceSeries).not_to receive(:where)
    get api_v1_methodology_path
    expect_documented_response(path: "/methodology")
    definition = response.parsed_body.fetch("data")
    expect(definition.fetch("version")).to eq("1.4-draft")
    inputs = definition.dig("score", "market_input_requirements")
    expect(inputs).to include("status" => "blocked", "coverage_evaluated" => false, "applicability_status" => "unresolved")
    requirements = inputs.fetch("requirements").index_by { |entry| entry.fetch("id") }
    expect(requirements.fetch("issuer_market_cap")).to include("storage_status" => "partial")
    expect(requirements.fetch("daily_dollar_volume")).to include("storage_status" => "partial", "scoring_status" => "unimplemented")
    expect(requirements.fetch("daily_dollar_volume").fetch("blockers")).to include("session_calendar", "minimum_session_coverage")
    expect(requirements.fetch("issuer_security_identity").fetch("blockers")).to include("effective_dated_identity")
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
