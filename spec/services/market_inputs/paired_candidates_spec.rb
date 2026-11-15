# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketInputs::PairedCandidates do
  let(:now) { Time.utc(2026, 11, 15, 12) }
  let(:identity_policy) { MarketInputs::IdentitySourcePolicy.new(sources: [ "identity_fixture" ]) }
  let(:scale_policy) { MarketInputs::ScaleSourcePolicy.new(sources: [ "scale_fixture" ], currency: "USD", measurement_basis: "issuer_equity", maximum_age_seconds: 3.days.to_i) }
  around { |example| travel_to(now) { example.run } }

  def identity(**overrides)
    security = create(:security)
    IssuerSecurityEvidence.create!({ security:, security_figi: security.figi, issuer_cik: "0000000123", cusip: "123456789",
      source: "identity_fixture", source_record_id: "identity", source_revision: "original",
      effective_from: now - 2.days, observed_at: now - 1.day, created_at: now }.merge(overrides))
  end

  def scale(**overrides)
    IssuerScaleObservation.create!({ issuer_cik: "0000000123", source: "scale_fixture", source_record_id: "scale", source_revision: "original",
      market_cap: "12345678901234567890.1234567890123456789", currency: "USD", measurement_basis: "issuer_equity",
      effective_at: now - 2.days, observed_at: now - 1.day, created_at: now }.merge(overrides))
  end

  def pair(at: now)
    described_class.new(cusip: "123456789", as_of: at, identity_policy:, scale_policy:).call
  end

  it "defaults to no sources and never queries scale after an unavailable identity" do
    expect(ApplicationRecord).not_to receive(:connection)
    expect(MarketInputs::ScaleCandidate).not_to receive(:new)
    result = described_class.new(cusip: "123456789", as_of: now).call
    expect(result).to have_attributes(status: "unavailable", reason: "identity_unavailable", readiness_certified: false,
      scale: nil, scale_attempted: false)
    expect(result.identity.reason).to eq("source_policy_missing")
    expect(result.policies.fetch(:scale)).to include(version: "scale-candidate-v1")
  end

  it "preserves the independent policy evidence, exact amount and common evaluation time" do
    item = identity
    amount = scale
    result = pair
    expect(result).to have_attributes(status: "paired_candidate", reason: nil, readiness_certified: false,
      scale_attempted: true, evaluated_at: now.iso8601(6))
    expect(result.identity).to have_attributes(evidence_id: item.id, policy_digest: identity_policy.digest, evaluated_at: result.evaluated_at)
    expect(result.scale).to have_attributes(observation_id: amount.id, issuer_cik: item.issuer_cik,
      policy_digest: scale_policy.digest, evaluated_at: result.evaluated_at)
    expect(result.scale.market_cap.to_s("F")).to eq("12345678901234567890.1234567890123456789")
    expect(result.policies.fetch(:identity)).to include(version: "identity-candidate-v1", digest: identity_policy.digest)
    expect(result.policies.fetch(:scale)).to include(version: "scale-candidate-v1", digest: scale_policy.digest)
    expect(ActivityMethodology.definition.dig("score", "status")).to eq("unavailable")
  end

  it "looks up only the issuer derived from identity instead of borrowing another issuer's amount" do
    identity
    scale(issuer_cik: "0000000456")
    result = pair
    expect(result).to have_attributes(status: "unavailable", reason: "scale_unavailable", scale_attempted: true)
    expect(result.scale).to have_attributes(reason: "no_applicable_observation", market_cap: nil)
  end

  it "skips scale when identity is ambiguous even if a cap value exists" do
    identity
    identity(source_record_id: "competing", issuer_cik: "0000000456")
    scale
    expect(MarketInputs::ScaleCandidate).not_to receive(:new)
    result = pair
    expect(result).to have_attributes(reason: "identity_unavailable", scale_attempted: false, scale: nil)
    expect(result.identity.reason).to eq("multiple_applicable_assertions")
  end

  it "retains scale's missing policy as distinct from a skipped scale lookup" do
    identity
    result = described_class.new(cusip: "123456789", as_of: now, identity_policy:).call
    expect(result).to have_attributes(reason: "scale_unavailable", scale_attempted: true)
    expect(result.scale).to have_attributes(reason: "source_policy_missing", candidate_count: nil)
  end

  it "retains zero and unresolved revision reasons without changing source records" do
    identity
    original = scale(market_cap: 0)
    expect(pair.scale.reason).to eq("unusable_amount")
    scale(source_revision: "revised", market_cap: 1)
    result = pair
    expect(result).to have_attributes(reason: "scale_unavailable", readiness_certified: false)
    expect(result.scale).to have_attributes(reason: "unresolved_revisions", market_cap: nil)
    expect(original.reload.market_cap).to eq(0)
  end

  it "keeps both historical candidates stable after later recorded corrections" do
    old_identity = identity(created_at: now - 1.day)
    old_scale = scale(created_at: now - 1.day)
    historical = now - 1.second
    before = pair(at: historical)
    IssuerSecurityEvidence.create!(old_identity.attributes.except("id").merge("source_revision" => "later", "created_at" => now))
    scale(source_revision: "later")
    after = pair(at: historical)
    expect(after).to eq(before)
    expect(after.scale.observation_id).to eq(old_scale.id)
    expect(pair).to have_attributes(reason: "identity_unavailable", scale_attempted: false)
  end

  it "rejects an identity timestamp mismatch before attempting scale" do
    identity
    selected = MarketInputs::IdentityCandidate.new(cusip: "123456789", as_of: now, policy: identity_policy).call
    selector = instance_double(MarketInputs::IdentityCandidate, call: selected.with(evaluated_at: (now - 1.second).iso8601(6)))
    allow(MarketInputs::IdentityCandidate).to receive(:new).and_return(selector)
    expect(MarketInputs::ScaleCandidate).not_to receive(:new)
    service = described_class.new(cusip: "123456789", as_of: now, identity_policy:, scale_policy:)
    expect(service.call).to have_attributes(reason: "identity_context_mismatch", scale_attempted: false)
  end

  [ { issuer_cik: "0000000456" }, { currency: "EUR" }, { measurement_basis: "share_class" },
    { policy_digest: "other" }, { policy_version: "other" }, { evaluated_at: "2000-01-01T00:00:00Z" } ].each do |override|
    it "withholds the pair when the scale result mismatches #{override.keys.first}" do
      identity
      scale
      original = MarketInputs::ScaleCandidate.new(issuer_cik: "0000000123", as_of: now, policy: scale_policy).call
      selector = instance_double(MarketInputs::ScaleCandidate, call: original.with(**override))
      allow(MarketInputs::ScaleCandidate).to receive(:new).and_return(selector)
      result = pair
      expect(result).to have_attributes(status: "unavailable", reason: "scale_context_mismatch", readiness_certified: false)
      expect(result.scale).to eq(selector.call)
    end
  end

  it "makes at most two aggregate reads and performs no writes, jobs, Redis or HTTP" do
    identity
    scale
    expect(Sidekiq).not_to receive(:redis)
    statements = []
    observer = ->(_name, _start, _finish, _id, payload) { statements << payload.fetch(:sql) unless payload[:cached] || payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { expect { pair }.not_to have_enqueued_job }
    expect(statements.size).to eq(2)
    expect(statements).to all(start_with("WITH known AS"))
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "validates both policies even when identity would be unavailable" do
    expect(ApplicationRecord).not_to receive(:connection)
    expect { described_class.new(cusip: "123456789", as_of: now, scale_policy: {}) }.to raise_error(ArgumentError)
    expect { described_class.new(cusip: "123456789", as_of: now, identity_policy: {}) }.to raise_error(ArgumentError)
  end

  it "propagates underlying database failures rather than fabricating a failed pair" do
    allow(ApplicationRecord).to receive(:connection).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect { pair }.to raise_error(ActiveRecord::ConnectionNotEstablished)
  end
end
