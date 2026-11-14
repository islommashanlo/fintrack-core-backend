# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketInputReadiness do
  let(:now) { Time.utc(2026, 11, 14, 12) }
  around { |example| travel_to(now) { example.run } }

  def scale(**overrides)
    IssuerScaleObservation.create!({ issuer_cik: "0000000123", source: "fixture", source_record_id: "private-source-record",
      source_revision: "1", market_cap: 100, currency: "USD", measurement_basis: "issuer_total_equity",
      effective_at: now - 2.days, observed_at: now - 1.day, created_at: now }.merge(overrides))
  end

  def evidence(security: create(:security), **overrides)
    IssuerSecurityEvidence.create!({ security:, issuer_cik: "0000000123", security_figi: security.figi,
      cusip: "123456789", ticker: "EXAMPLE", source: "fixture", source_record_id: "private-source-record", source_revision: "1",
      effective_from: now - 2.days, observed_at: now - 1.day, created_at: now }.merge(overrides))
  end

  def report(at: now)
    described_class.new(now: at).to_h.deep_stringify_keys
  end

  it "keeps empty stores unverified rather than certifying readiness from zero issues" do
    result = report
    expect(result).to include("status" => "unverified", "readiness_certified" => false, "as_of" => now.iso8601)
    expect(result.fetch("requirements")).to include("coverage_evaluated" => false)
    expect(result.fetch("scale_observations").values).to all(eq(0))
    expect(result.fetch("identity_evidence").values).to all(eq(0))
    expect(result.fetch("price_bars").values).to all(eq(0))
  end

  it "counts known scale revisions and reported zeros without selecting, summing or converting values" do
    scale
    scale(source_revision: "2", market_cap: 0)
    scale(source: "another", currency: "EUR")
    scale(source_record_id: "later", observed_at: now + 1.day, created_at: now + 1.day)
    expect(report.fetch("scale_observations")).to eq("recorded_count" => 3, "candidate_count" => 3,
      "issuer_count" => 1, "source_count" => 2, "zero_amount_count" => 1, "multiple_revision_groups" => 1)
    expect(report.fetch("readiness_certified")).to be(false)
  end

  it "keeps newly recorded backdated observations out of earlier inventories" do
    scale
    evidence
    result = report(at: now - 1.second)
    expect(result.dig("scale_observations", "recorded_count")).to eq(0)
    expect(result.dig("identity_evidence", "recorded_count")).to eq(0)
  end

  it "reports identifier and alias collisions separately from repeated source revisions" do
    first = evidence
    evidence(security: first.security, source_revision: "2")
    evidence(security: first.security, issuer_cik: "0000000456", source: "another")
    evidence(issuer_cik: "0000000789", source: "third")
    expect(report.fetch("identity_evidence")).to include("candidate_count" => 4, "issuer_count" => 3,
      "source_count" => 3, "multiple_revision_groups" => 1, "multi_issuer_figi_groups" => 1, "multi_issuer_cusip_groups" => 1)
  end

  it "uses inclusive starts and exclusive ends without counting future announcements as current candidates" do
    evidence(effective_from: now)
    evidence(source_record_id: "ended", effective_to: now)
    evidence(source_record_id: "future", effective_from: now + 1.day)
    expect(report.fetch("identity_evidence")).to include("recorded_count" => 3, "candidate_count" => 1)
  end

  it "exposes missing aliases and current identifier mismatch without changing the source snapshot" do
    item = evidence(cusip: nil, ticker: nil)
    original = item.security_figi
    item.security.update!(figi: "changed-current-identifier")
    expect(report.fetch("identity_evidence")).to include("missing_cusip_count" => 1, "missing_ticker_count" => 1,
      "current_identifier_mismatch_count" => 1, "multi_issuer_figi_groups" => 0, "multi_issuer_cusip_groups" => 0)
    expect(item.reload.security_figi).to eq(original)
  end

  it "counts observed bars without claiming session completeness, dollar volume or source rights" do
    series = price_series
    attributes = market_bars.first.to_h.merge(price_series: series, observed_at: now)
    PriceDaily.create!(attributes.merge(session_date: now.to_date))
    PriceDaily.create!(attributes.merge(session_date: now.to_date + 1.day))
    PriceDaily.create!(attributes.merge(session_date: now.to_date - 1.day, observed_at: now + 1.day))
    expect(report.fetch("price_bars")).to eq("recorded_count" => 3, "observed_bar_count" => 1,
      "series_count" => 1, "source_count" => 1)
    expect(report.fetch("readiness_certified")).to be(false)
  end

  it "uses only three aggregate reads and never enumerates rows, touches Redis or makes HTTP requests" do
    scale
    evidence
    expect(Sidekiq).not_to receive(:redis)
    expect(IssuerScaleObservation).not_to receive(:all)
    statements = []
    observer = ->(_name, _start, _finish, _id, payload) { statements << payload.fetch(:sql) unless payload[:cached] || payload[:name] == "SCHEMA" }
    result = nil
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { result = report }
    expect(statements.size).to be_between(1, 3)
    expect(statements).to all(match(/\AWITH /))
    expect(result.to_json).not_to include("private-source-record")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "does not modify records, enqueue jobs or activate the methodology" do
    item = scale
    snapshot = item.attributes
    expect { report }.not_to have_enqueued_job
    expect(item.reload.attributes).to eq(snapshot)
    expect(ActivityMethodology.definition.dig("score", "status")).to eq("unavailable")
  end

  it "propagates database failures instead of returning fabricated empty coverage" do
    allow(ApplicationRecord).to receive(:connection).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect { report }.to raise_error(ActiveRecord::ConnectionNotEstablished)
  end
end
