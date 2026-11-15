# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator market-input preview" do
  let(:path) { "/ops/market-inputs/preview" }
  let(:now) { Time.utc(2026, 11, 15, 12) }
  let(:headers) { { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("ops", "correct horse") } }
  let(:parameters) { { cusip: "123456789", as_of: now.iso8601(6) } }

  around do |example|
    original = ENV.to_h.slice("OPS_USERNAME", "OPS_PASSWORD")
    ENV["OPS_USERNAME"], ENV["OPS_PASSWORD"] = "ops", "correct horse"
    travel_to(now) { example.run }
  ensure
    %w[OPS_USERNAME OPS_PASSWORD].each { |key| ENV[key] = original[key] }
  end

  def configured_policy
    MarketInputs::PreviewPolicy::Result.new(
      identity_policy: MarketInputs::IdentitySourcePolicy.new(sources: [ "fixture" ]),
      scale_policy: MarketInputs::ScaleSourcePolicy.new(sources: [ "fixture" ], currency: "USD", measurement_basis: "issuer_equity", maximum_age_seconds: 3.days.to_i))
  end

  def records
    security = create(:security)
    identity = IssuerSecurityEvidence.create!(security:, security_figi: security.figi, issuer_cik: "0000000123", cusip: "123456789",
      source: "fixture", source_record_id: "identity", source_revision: "original", effective_from: now - 2.days, observed_at: now - 1.day)
    scale = IssuerScaleObservation.create!(issuer_cik: identity.issuer_cik, source: "fixture", source_record_id: "scale", source_revision: "original",
      market_cap: "12345678901234567890.1234567890123456789", currency: "USD", measurement_basis: "issuer_equity",
      effective_at: now - 2.days, observed_at: now - 1.day)
    [ identity, scale ]
  end

  it "requires ops credentials before validating parameters or loading source policy" do
    expect(MarketInputs::PreviewPolicy).not_to receive(:load)
    get path
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers.fetch("Cache-Control")).to include("no-store")
    get path, headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("ops", "wrong") }
    expect(response).to have_http_status(:unauthorized)
    ENV.delete("OPS_USERNAME")
    ENV.delete("OPS_PASSWORD")
    get path, headers: headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "uses the checked-in deny-by-default policy and returns private unavailable diagnostics" do
    expect(ApplicationRecord).not_to receive(:connection)
    get path, params: parameters, headers: headers
    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch("data")
    expect(data).to include("status" => "unavailable", "readiness_certified" => false, "scale_attempted" => false, "scale" => nil)
    expect(data.dig("identity", "reason")).to eq("source_policy_missing")
    expect(data.dig("identity", "candidate_count")).to be_nil
    expect(data.dig("policies", "scale", "version")).to eq("scale-candidate-v1")
    expect(response.headers.fetch("Cache-Control")).to include("private", "no-store")
    expect(response.headers.fetch("Pragma")).to eq("no-cache")
    expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
  end

  it "serializes both actual stage results and exact decimals under a server-owned test policy" do
    identity, scale = records
    policy = configured_policy
    allow(MarketInputs::PreviewPolicy).to receive(:load).and_return(policy)
    get path, params: parameters, headers: headers
    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch("data")
    expect(data).to include("status" => "paired_candidate", "readiness_certified" => false, "scale_attempted" => true)
    expect(data.dig("identity", "evidence_id")).to eq(identity.id)
    expect(data.dig("scale", "observation_id")).to eq(scale.id)
    expect(data.dig("scale", "market_cap")).to eq("12345678901234567890.1234567890123456789")
    expect(data.dig("identity", "evaluated_at")).to eq(data.fetch("evaluated_at"))
    expect(data.dig("scale", "evaluated_at")).to eq(data.fetch("evaluated_at"))
    expect(data.dig("policies", "identity", "digest")).to eq(policy.identity_policy.digest)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  [ {}, { cusip: "123456789" }, { as_of: "2026-11-15T12:00:00Z" } ].each do |values|
    it "requires both explicit scope fields #{values.inspect}" do
      expect(MarketInputs::PreviewPolicy).not_to receive(:load)
      get path, params: values, headers: headers
      expect(response).to have_http_status(:bad_request)
    end
  end

  [
    { cusip: [ "123456789" ] }, { cusip: "123456789\n" }, { cusip: "bad" },
    { as_of: "2026-02-30T00:00:00Z" }, { as_of: "2026-11-15" }, { as_of: "2026-11-15T12:00:01Z" },
    { as_of: "2026-11-15T24:00:00Z" }, { as_of: "2026-11-15T12:00:60Z" }, { as_of: "0000-01-01T00:00:00Z" },
    { as_of: "2026-11-15T12:00:00" }, { as_of: "x" * 1000 }, { as_of: [] },
    { sources: [ "fixture" ] }, { policy: { sources: [ "fixture" ] } }, { currency: "USD" },
    { maximum_age_seconds: 999 }, { issuer_cik: "0000000123" }, { profile: "approved" } ].each do |override|
    it "rejects malformed input or policy override #{override.inspect}" do
      expect(MarketInputs::PreviewPolicy).not_to receive(:load)
      values = parameters.merge(override)
      get path, params: values, headers: headers
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("INVALID_PARAMETERS")
      expect(response.headers.fetch("Cache-Control")).to include("no-store")
    end
  end

  it "normalizes offset timestamps and allows the exact current boundary" do
    get path, params: parameters.merge(as_of: "2026-11-15T07:00:00-05:00"), headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "evaluated_at")).to eq(now.iso8601(6))
  end

  it "preserves unavailable stage reasons and performs no writes or jobs" do
    identity, scale = records
    allow(MarketInputs::PreviewPolicy).to receive(:load).and_return(configured_policy)
    scale_snapshot = scale.attributes
    scale_row = scale.attributes.except("id").merge("source_revision" => "later")
    IssuerScaleObservation.insert_all!([ scale_row ])
    expect { get path, params: parameters, headers: headers }.not_to have_enqueued_job
    expect(response.parsed_body.dig("data", "reason")).to eq("scale_unavailable")
    expect(response.parsed_body.dig("data", "scale", "reason")).to eq("unresolved_revisions")
    expect(response.parsed_body.dig("data", "scale", "market_cap")).to be_nil
    expect(scale.reload.attributes).to eq(scale_snapshot)
    expect(identity.reload.source_revision).to eq("original")
    expect(ActivityMethodology.definition.dig("score", "status")).to eq("unavailable")
  end

  it "does not disguise broken server policy as client validation failure" do
    allow(MarketInputs::PreviewPolicy).to receive(:load).and_raise(ArgumentError, "Invalid operator preview policy")
    expect { get path, params: parameters, headers: headers }.to raise_error(ArgumentError, "Invalid operator preview policy")
  end
end
