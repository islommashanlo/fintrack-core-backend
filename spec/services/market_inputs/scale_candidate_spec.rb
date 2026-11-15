# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketInputs::ScaleCandidate do
  let(:now) { Time.utc(2026, 11, 15, 12) }
  let(:policy) { MarketInputs::ScaleSourcePolicy.new(sources: [ "fixture" ], currency: "USD", measurement_basis: "issuer_equity", maximum_age_seconds: 3.days.to_i) }
  around { |example| travel_to(now) { example.run } }

  def observation(**overrides)
    IssuerScaleObservation.create!({ issuer_cik: "0000000123", source: "fixture", source_record_id: "one-observation", source_revision: "original",
      market_cap: "12345678901234567890.1234567890123456789", currency: "USD", measurement_basis: "issuer_equity",
      effective_at: now - 2.days, observed_at: now - 1.day, created_at: now }.merge(overrides))
  end

  def select_candidate(at: now)
    described_class.new(issuer_cik: "0000000123", as_of: at, policy:).call
  end

  it "defaults to no sources without looking up data or reporting fabricated zero counts" do
    expect(ApplicationRecord).not_to receive(:connection)
    expect(described_class.new(issuer_cik: "0000000123", as_of: now).call)
      .to have_attributes(status: "unavailable", reason: "source_policy_missing", market_cap: nil, candidate_count: nil, revision_groups: nil)
  end

  it "preserves exact decimals and the explicit policy identity for a single candidate" do
    item = observation
    result = select_candidate
    expect(result).to have_attributes(status: "candidate", reason: nil, observation_id: item.id, issuer_cik: item.issuer_cik,
      currency: "USD", measurement_basis: "issuer_equity", candidate_count: 1, revision_groups: 0,
      policy_version: "scale-candidate-v1", policy_digest: policy.digest, evaluated_at: now.iso8601(6))
    expect(result.market_cap.to_s("F")).to eq("12345678901234567890.1234567890123456789")
    expect(ActivityMethodology.definition.dig("score", "status")).to eq("unavailable")
  end

  it "does not fall back to other sources, currencies or measurement bases" do
    observation(source: "another")
    observation(source_record_id: "currency", currency: "EUR")
    observation(source_record_id: "basis", measurement_basis: "share_class")
    expect(select_candidate).to have_attributes(reason: "no_applicable_observation", candidate_count: 0, market_cap: nil)
  end

  it "does not prefer a newer or larger independent observation" do
    observation
    observation(source_record_id: "another", market_cap: 42, effective_at: now - 1.day)
    expect(select_candidate).to have_attributes(reason: "multiple_applicable_observations", candidate_count: 2,
      observation_id: nil, issuer_cik: nil, market_cap: nil, currency: nil, measurement_basis: nil)
  end

  it "does not select even identical observations by voting or deduplication" do
    observation
    observation(source_record_id: "another")
    expect(select_candidate).to have_attributes(reason: "multiple_applicable_observations", market_cap: nil)
  end

  it "rejects a sole zero amount without changing the recorded value" do
    item = observation(market_cap: 0)
    expect(select_candidate).to have_attributes(reason: "unusable_amount", observation_id: nil, market_cap: nil, candidate_count: 1)
    expect(item.reload.market_cap).to eq(0)
  end

  it "does not filter out a competing zero to choose a positive observation" do
    observation
    observation(source_record_id: "zero", market_cap: 0)
    expect(select_candidate).to have_attributes(reason: "multiple_applicable_observations", market_cap: nil)
  end

  it "checks revisions before currency, basis and freshness filtering" do
    observation
    observation(source_revision: "corrected", currency: "EUR", measurement_basis: "share_class", effective_at: now - 10.days)
    expect(select_candidate).to have_attributes(reason: "unresolved_revisions", revision_groups: 1, candidate_count: 1, market_cap: nil)
  end

  it "checks known corrections that change the issuer" do
    observation
    observation(source_revision: "corrected", issuer_cik: "0000000456")
    expect(select_candidate).to have_attributes(reason: "unresolved_revisions", market_cap: nil)
  end

  it "does not interpret revision labels as an order" do
    observation(source_revision: "zzz")
    observation(source_revision: "001", market_cap: 0)
    expect(select_candidate).to have_attributes(reason: "unresolved_revisions", market_cap: nil)
  end

  it "excludes later recorded backdated corrections from an earlier evaluation" do
    item = observation(created_at: now - 1.day)
    observation(source_revision: "correction")
    expect(select_candidate(at: now - 1.second)).to have_attributes(status: "candidate", observation_id: item.id)
    expect(select_candidate).to have_attributes(reason: "unresolved_revisions", observation_id: nil)
  end

  it "uses an inclusive freshness cutoff and refuses stale observations" do
    item = observation(effective_at: now - 3.days)
    expect(select_candidate).to have_attributes(observation_id: item.id)
    expect(select_candidate(at: now + 1.second)).to have_attributes(reason: "no_applicable_observation", market_cap: nil)
  end

  it "does not admit future observed or recorded values" do
    observation(effective_at: now, observed_at: now + 1.day, created_at: now + 1.day)
    expect(select_candidate).to have_attributes(reason: "no_applicable_observation", candidate_count: 0)
  end

  it "quotes an exact source basis rather than treating it as SQL" do
    basis = "issuer' OR TRUE --"
    item = observation(measurement_basis: basis)
    custom = MarketInputs::ScaleSourcePolicy.new(sources: [ "fixture" ], currency: "USD", measurement_basis: basis, maximum_age_seconds: 3.days.to_i)
    expect(described_class.new(issuer_cik: item.issuer_cik, as_of: now, policy: custom).call).to have_attributes(observation_id: item.id)
    expect(select_candidate).to have_attributes(reason: "no_applicable_observation")
  end

  it "normalizes a zoned timestamp without modifying the caller" do
    item = observation
    zoned = ActiveSupport::TimeZone["America/New_York"].local(2026, 11, 15, 7)
    result = described_class.new(issuer_cik: item.issuer_cik, as_of: zoned, policy:).call
    expect(result).to have_attributes(observation_id: item.id, evaluated_at: now.iso8601(6))
    expect(zoned).not_to be_frozen
  end

  it "uses one aggregate read with no writes, jobs, Redis, HTTP or identity-cache fallback" do
    item = observation
    expect(CusipSecurityMapping).not_to receive(:where)
    expect(Sidekiq).not_to receive(:redis)
    queries = []
    observer = ->(_name, _start, _finish, _id, payload) { queries << payload.fetch(:sql) unless payload[:cached] || payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      expect { select_candidate }.not_to have_enqueued_job
    end
    expect(queries.size).to eq(1)
    expect(queries.sole).to start_with("WITH known AS")
    expect(item.reload.source_revision).to eq("original")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects malformed arguments before SQL" do
    expect(ApplicationRecord).not_to receive(:connection)
    expect { described_class.new(issuer_cik: "x' OR TRUE --", as_of: now, policy:) }.to raise_error(ArgumentError)
    expect { described_class.new(issuer_cik: "0000000123", as_of: "now", policy:) }.to raise_error(ArgumentError)
    expect { described_class.new(issuer_cik: "0000000123", as_of: now, policy: {}) }.to raise_error(ArgumentError)
  end

  it "propagates database errors instead of fabricating an empty candidate set" do
    allow(ApplicationRecord).to receive(:connection).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect { select_candidate }.to raise_error(ActiveRecord::ConnectionNotEstablished)
  end
end
