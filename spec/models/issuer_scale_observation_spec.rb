# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssuerScaleObservation do
  let(:now) { Time.utc(2026, 11, 14, 12) }
  around { |example| travel_to(now) { example.run } }

  def attributes
    { issuer_cik: "0000000123", source: "fixture", source_record_id: "cap-20261113", source_revision: "1",
      market_cap: "12345678901234567890.1234567890123456789", currency: "USD", measurement_basis: "issuer_total_equity",
      effective_at: now - 2.days, observed_at: now - 1.day, created_at: now }
  end

  it "round-trips the exact currency-unit amount without float rounding or FX conversion" do
    record = described_class.create!(attributes)
    expect(record.reload.market_cap.to_s("F")).to eq(attributes.fetch(:market_cap))
    expect(record.currency).to eq("USD")
  end

  it "keeps source revisions as separate immutable records" do
    original = described_class.create!(attributes)
    revised = described_class.create!(attributes.merge(source_revision: "2", market_cap: "42"))
    expect(described_class.count).to eq(2)
    expect(original.reload.market_cap.to_s("F")).to eq(attributes.fetch(:market_cap))
    expect { original.update!(market_cap: 42) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { revised.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(original.reload).to be_persisted
  end

  it "enforces the source revision identity even when validation is bypassed" do
    described_class.insert_all!([ attributes ])
    expect { described_class.insert_all!([ attributes ]) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "does not choose between sources, bases or revisions when listing known candidates" do
    first = described_class.create!(attributes)
    second = described_class.create!(attributes.merge(source: "another", measurement_basis: "share_class_equity", currency: "EUR"))
    expect(described_class.known_at(now).pluck(:id)).to match_array([ first.id, second.id ])
  end

  it "requires effective, observed and recording times all to be within the as-of boundary" do
    known = described_class.create!(attributes.merge(source_revision: "known", created_at: now - 1.day))
    just_observed = described_class.create!(attributes.merge(source_revision: "observed", observed_at: now))
    recorded_later = described_class.create!(attributes.merge(source_revision: "recorded"))
    expect(described_class.known_at(now - 1.second).pluck(:id)).to eq([ known.id ])
    expect(described_class.known_at(now).pluck(:id)).to match_array([ known.id, just_observed.id, recorded_later.id ])
    expect(described_class.known_at(now - 3.days)).to be_empty
  end

  [ "NaN", "Infinity", "-Infinity", "-1" ].each do |value|
    it "rejects invalid market-cap value #{value} through model and database" do
      expect(described_class.new(attributes.merge(market_cap: value))).not_to be_valid
      expect { described_class.insert_all!([ attributes.merge(market_cap: value) ]) }
        .to raise_error(ActiveRecord::StatementInvalid, /issuer_scale_amount/)
    end
  end

  [ { issuer_cik: "123" }, { issuer_cik: "0000000123\n" }, { source: "Unknown Provider" },
    { source_record_id: " " }, { source_record_id: "x" * 201 }, { source_revision: "\t" },
    { measurement_basis: " " }, { currency: "usd" } ].each do |override|
    it "rejects invalid source metadata #{override.keys.first}" do
      expect(described_class.new(attributes.merge(override))).not_to be_valid
      expect { described_class.insert_all!([ attributes.merge(override) ]) }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  %w[effective_at observed_at].each do |field|
    it "rejects reversed #{field} at both model and database boundaries" do
      override = { field.to_sym => field == "effective_at" ? now : now + 1.second }
      expect(described_class.new(attributes.merge(override))).not_to be_valid
      expect { described_class.insert_all!([ attributes.merge(override) ]) }
        .to raise_error(ActiveRecord::StatementInvalid, /issuer_scale_times/)
    end
  end

  it "rejects infinite database timestamps instead of admitting unknown knowledge times" do
    expect { described_class.insert_all!([ attributes.merge(effective_at: "-infinity") ]) }
      .to raise_error(ActiveRecord::StatementInvalid, /issuer_scale_times/)
  end

  it "allows a reported zero without treating it as a usable scoring denominator" do
    expect(described_class.create!(attributes.merge(market_cap: 0)).market_cap).to eq(0)
    expect(ActivityMethodology.definition.dig("score", "status")).to eq("unavailable")
  end
end
