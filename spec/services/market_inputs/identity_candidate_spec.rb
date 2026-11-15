# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketInputs::IdentityCandidate do
  let(:now) { Time.utc(2026, 11, 15, 12) }
  let(:security) { create(:security) }
  let(:policy) { MarketInputs::IdentitySourcePolicy.new(sources: [ "fixture" ]) }
  around { |example| travel_to(now) { example.run } }

  def evidence(**overrides)
    IssuerSecurityEvidence.create!({ security:, security_figi: security.figi, issuer_cik: "0000000123", cusip: "123456789",
      source: "fixture", source_record_id: "one-assertion", source_revision: "original",
      effective_from: now - 2.days, observed_at: now - 1.day, created_at: now }.merge(overrides))
  end

  def select_candidate(at: now)
    described_class.new(cusip: "123456789", as_of: at, policy:).call
  end

  it "defaults to no sources and performs no database read" do
    expect(ApplicationRecord).not_to receive(:connection)
    result = described_class.new(cusip: "123456789", as_of: now).call
    expect(result).to have_attributes(status: "unavailable", reason: "source_policy_missing", evidence_id: nil,
      candidate_count: nil, revision_groups: nil)
  end

  it "selects a single assertion without certifying it or publishing a score" do
    item = evidence
    expect(select_candidate).to have_attributes(status: "candidate", reason: nil, evidence_id: item.id,
      issuer_cik: item.issuer_cik, security_figi: item.security_figi, candidate_count: 1, revision_groups: 0,
      policy_version: "identity-candidate-v1", policy_digest: policy.digest, evaluated_at: now.iso8601(6))
    expect(ActivityMethodology.definition.dig("score", "status")).to eq("unavailable")
  end

  it "does not fall back to unlisted sources" do
    evidence(source: "not_authorized")
    expect(select_candidate).to have_attributes(status: "unavailable", reason: "no_applicable_assertion", evidence_id: nil, candidate_count: 0)
  end

  it "withholds multiple independent assertions, even when they agree" do
    evidence
    evidence(source_record_id: "another-assertion")
    expect(select_candidate).to have_attributes(status: "unavailable", reason: "multiple_applicable_assertions",
      evidence_id: nil, issuer_cik: nil, security_figi: nil, candidate_count: 2)
  end

  it "keeps competing issuer assertions unresolved without ranking sources" do
    evidence
    evidence(source: "another", issuer_cik: "0000000456")
    other_policy = MarketInputs::IdentitySourcePolicy.new(sources: %w[another fixture])
    result = described_class.new(cusip: "123456789", as_of: now, policy: other_policy).call
    expect(result).to have_attributes(status: "unavailable", reason: "multiple_applicable_assertions", evidence_id: nil)
  end

  it "does not resurrect an older open assertion after a known closing revision" do
    evidence
    evidence(source_revision: "closed", effective_to: now)
    expect(select_candidate).to have_attributes(status: "unavailable", reason: "unresolved_revisions",
      candidate_count: 1, revision_groups: 1, evidence_id: nil)
  end

  it "checks known revisions before filtering changed CUSIPs or issuers" do
    evidence
    evidence(source_revision: "corrected", cusip: "987654321", issuer_cik: "0000000456")
    expect(select_candidate).to have_attributes(reason: "unresolved_revisions", evidence_id: nil, candidate_count: 1)
  end

  it "detects a corrected source record that moves to another security" do
    evidence
    replacement = create(:security)
    evidence(source_revision: "corrected", security: replacement, security_figi: replacement.figi, cusip: nil)
    expect(select_candidate).to have_attributes(reason: "unresolved_revisions", evidence_id: nil, revision_groups: 1)
  end

  it "does not interpret opaque revision labels or timestamps as source priority" do
    evidence(source_revision: "zzz", created_at: now - 1.day)
    evidence(source_revision: "001")
    expect(select_candidate).to have_attributes(reason: "unresolved_revisions", evidence_id: nil)
  end

  it "excludes later recorded backdated revisions from an earlier knowledge snapshot" do
    original = evidence(created_at: now - 1.day)
    evidence(source_revision: "later")
    expect(select_candidate(at: now - 1.second)).to have_attributes(status: "candidate", evidence_id: original.id, revision_groups: 0)
    expect(select_candidate).to have_attributes(reason: "unresolved_revisions", evidence_id: nil)
  end

  it "applies inclusive starts and exclusive ends after the revision check" do
    item = evidence(effective_from: now, effective_to: now + 1.day)
    expect(select_candidate(at: now - 1.second)).to have_attributes(reason: "no_applicable_assertion")
    expect(select_candidate).to have_attributes(evidence_id: item.id)
    expect(select_candidate(at: now + 1.day)).to have_attributes(reason: "no_applicable_assertion")
  end

  it "does not let a future source revision silently schedule supersession" do
    evidence
    evidence(source_revision: "announced", effective_from: now + 1.day)
    expect(select_candidate).to have_attributes(reason: "unresolved_revisions", candidate_count: 1, evidence_id: nil)
  end

  it "uses snapshot identifiers instead of borrowing current metadata" do
    item = evidence
    original = item.security_figi
    security.update!(figi: "changed-current-identifier")
    expect(select_candidate).to have_attributes(evidence_id: item.id, security_figi: original)
  end

  it "does not involve current CUSIP caches, providers, Redis, jobs or writes" do
    item = evidence
    expect(CusipSecurityMapping).not_to receive(:where)
    expect(Sidekiq).not_to receive(:redis)
    statements = []
    observer = ->(_name, _start, _finish, _id, payload) { statements << payload.fetch(:sql) unless payload[:cached] || payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      expect { select_candidate }.not_to have_enqueued_job
    end
    expect(statements.size).to eq(1)
    expect(statements.sole).to start_with("WITH known AS")
    expect(item.reload.source_revision).to eq("original")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "normalizes zoned times without freezing or changing caller-owned inputs" do
    item = evidence
    zoned = ActiveSupport::TimeZone["America/New_York"].local(2026, 11, 15, 7)
    result = described_class.new(cusip: "123456789", as_of: zoned, policy:).call
    expect(result).to have_attributes(evidence_id: item.id, evaluated_at: now.iso8601(6))
    expect(zoned).not_to be_frozen
  end

  it "rejects malformed identifiers, times and policy objects before SQL" do
    expect(ApplicationRecord).not_to receive(:connection)
    expect { described_class.new(cusip: "x' OR TRUE --", as_of: now, policy:) }.to raise_error(ArgumentError)
    expect { described_class.new(cusip: "123456789", as_of: "now", policy:) }.to raise_error(ArgumentError)
    expect { described_class.new(cusip: "123456789", as_of: now, policy: {}) }.to raise_error(ArgumentError)
  end

  it "propagates database failures instead of fabricating no candidates" do
    allow(ApplicationRecord).to receive(:connection).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect { select_candidate }.to raise_error(ActiveRecord::ConnectionNotEstablished)
  end
end
