# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssuerSecurityEvidence do
  let(:now) { Time.utc(2026, 11, 14, 12) }
  let(:security) { create(:security, ticker: "EXAMPLE") }
  around { |example| travel_to(now) { example.run } }

  def attributes
    { issuer_cik: "0000000123", security_id: security.id, security_figi: security.figi,
      cusip: "123456789", ticker: "EXAMPLE", source: "fixture", source_record_id: "identity-1", source_revision: "1",
      effective_from: now - 10.days, effective_to: nil, observed_at: now - 1.day, created_at: now }
  end

  def candidates(effective_at: now, known_at: now)
    described_class.applicable_at(effective_at:, known_at:).pluck(:id)
  end

  it "uses an inclusive start and exclusive end for the effective interval" do
    record = described_class.create!(attributes.merge(effective_from: now, effective_to: now + 1.day))
    expect(candidates(effective_at: now - 1.second)).to be_empty
    expect(candidates(effective_at: now)).to eq([ record.id ])
    expect(candidates(effective_at: now + 1.day - 1.second)).to eq([ record.id ])
    expect(candidates(effective_at: now + 1.day)).to be_empty
  end

  it "keeps backdated evidence out of earlier knowledge snapshots" do
    record = described_class.create!(attributes)
    expect(candidates(known_at: now - 1.second)).to be_empty
    expect(candidates(known_at: now)).to eq([ record.id ])
  end

  it "requires observation time as well as recording time to be known" do
    record = described_class.create!(attributes.merge(observed_at: now))
    expect(candidates(known_at: now - 1.second)).to be_empty
    expect(candidates(known_at: now)).to eq([ record.id ])
  end

  it "keeps economic and knowledge clocks independent for announced future intervals" do
    record = described_class.create!(attributes.merge(effective_from: now + 1.day))
    expect(candidates).to be_empty
    expect(candidates(effective_at: now + 1.day, known_at: now)).to eq([ record.id ])
  end

  it "retains conflicting issuer assertions instead of selecting a source winner" do
    first = described_class.create!(attributes)
    conflicting = described_class.create!(attributes.merge(issuer_cik: "0000000456", source: "another"))
    expect(candidates).to match_array([ first.id, conflicting.id ])
  end

  it "requires an existing local security but preserves the source snapshot after current metadata changes" do
    record = described_class.create!(attributes)
    figi = record.security_figi
    security.update!(figi: "changed-current-identifier", ticker: "CHANGED")
    expect(record.reload.attributes).to include("security_figi" => figi, "ticker" => "EXAMPLE", "cusip" => "123456789")
    expect(candidates).to eq([ record.id ])
  end

  it "rejects a mismatched local identifier at the model boundary without overwriting source input" do
    record = described_class.new(attributes.merge(security_figi: "different"))
    expect(record).not_to be_valid
    expect(record.security_figi).to eq("different")
  end

  it "keeps revisions separate and read-only through ordinary record APIs" do
    original = described_class.create!(attributes)
    revision = described_class.create!(attributes.merge(source_revision: "2", effective_to: now))
    expect(described_class.count).to eq(2)
    expect { original.update!(effective_to: now) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { revision.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(original.reload.effective_to).to be_nil
  end

  it "enforces source assertion identity in PostgreSQL" do
    described_class.insert_all!([ attributes ])
    expect { described_class.insert_all!([ attributes ]) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "restricts removal of a referenced local security" do
    described_class.create!(attributes)
    expect { security.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
  end

  it "enforces the security reference in PostgreSQL" do
    expect { described_class.insert_all!([ attributes.merge(security_id: -1) ]) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  [ { issuer_cik: "123" }, { issuer_cik: "0000000123\n" }, { source: "Invalid Source" },
    { security_figi: " " }, { security_figi: "x" * 65 }, { source_record_id: "\t" },
    { source_revision: "x" * 101 }, { cusip: "bad" }, { ticker: " " }, { ticker: "x" * 41 } ].each do |override|
    it "rejects invalid #{override.keys.first} metadata at model and database boundaries" do
      expect(described_class.new(attributes.merge(override))).not_to be_valid
      expect { described_class.insert_all!([ attributes.merge(override) ]) }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  it "allows missing source aliases without borrowing current ticker or CUSIP data" do
    record = described_class.create!(attributes.merge(cusip: nil, ticker: nil))
    expect(record.reload.attributes).to include("cusip" => nil, "ticker" => nil)
  end

  it "rejects a zero-length interval at both boundaries" do
    invalid = attributes.merge(effective_to: attributes.fetch(:effective_from))
    expect(described_class.new(invalid)).not_to be_valid
    expect { described_class.insert_all!([ invalid ]) }.to raise_error(ActiveRecord::StatementInvalid, /issuer_security_evidence_times/)
  end

  it "rejects a future observation at both boundaries" do
    invalid = attributes.merge(observed_at: now + 1.second)
    expect(described_class.new(invalid)).not_to be_valid
    expect { described_class.insert_all!([ invalid ]) }.to raise_error(ActiveRecord::StatementInvalid, /issuer_security_evidence_times/)
  end

  it "rejects infinite database interval boundaries" do
    expect { described_class.insert_all!([ attributes.merge(effective_from: "-infinity") ]) }
      .to raise_error(ActiveRecord::StatementInvalid, /issuer_security_evidence_times/)
  end
end
