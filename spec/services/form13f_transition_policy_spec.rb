# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Verified 13F unit transition" do
  let(:policy) { Form13fValueUnitPolicy.load }
  let(:accession) { "0001104659-23-000314" }

  it "uses the official filing date at the January 3 compliance boundary" do
    expect(policy.unit_for(accession, filed_on: Date.new(2023, 1, 2))).to eq("thousands")
    expect(policy.unit_for(accession, filed_on: Date.new(2023, 1, 3))).to eq("whole_dollars")
    expect(policy.unit_for(accession, filed_on: Date.new(2023, 1, 4))).to eq("whole_dollars")
    expect(policy.unit_for(accession)).to eq("unresolved")
  end

  it "does not infer the official filing date from an acceptance timestamp or date string" do
    expect { policy.unit_for(accession, filed_on: Time.utc(2023, 1, 3)) }.to raise_error(ArgumentError)
    expect { policy.unit_for(accession, filed_on: "2023-01-03") }.to raise_error(ArgumentError)
  end

  it "applies reviewed unresolved exceptions before the general date convention" do
    expect(policy.unit_for("0001725547-23-000003", filed_on: Date.new(2023, 1, 5))).to eq("unresolved")
    explicit = Form13fValueUnitPolicy.new(assignments: {
      accession => { "value_unit" => "unresolved", "evidence" => "Test exception requiring review" }
    })
    expect(explicit.unit_for(accession, filed_on: Date.new(2023, 1, 3))).to eq("unresolved")
  end

  it "includes real restatements in cover parser fixture coverage" do
    cover = Form13fCoverParser.parse(form13f_cover(:boundary_on_20230103))
    expect(cover).to have_attributes(submission_type: "13F-HR/A", amendment_type: "RESTATEMENT", period_of_report: Date.new(2022, 12, 31))
  end

  it "retains the observed old-quarter discrepancy without asserting a corrective multiplier" do
    original = Form13fInformationTableParser.parse(form13f_information(:old_period_original_20220809))
    restatement = Form13fInformationTableParser.parse(form13f_information(:old_period_restatement_20230105))
    key = ->(row) { [ row.cusip, row.put_call, row.share_type ] }
    groups = original.group_by(&key)
    expect(groups.values).to all(have_attributes(length: 1))
    ratios = restatement.map do |row|
      before = groups.fetch(key.call(row)).sole
      (row.value_reported / row.shares) / (before.value_reported / before.shares)
    end
    expect(ratios.length).to eq(60)
    expect(ratios).to all(be_between(BigDecimal("0.95"), BigDecimal("1.05")))
    normalized = Form13fValueNormalizer.normalize(value_reported: restatement.first.value_reported,
      value_unit: policy.unit_for("0001725547-23-000003", filed_on: Date.new(2023, 1, 5)))
    expect(normalized).to have_attributes(value_usd: nil, suspect: true, value_reported: restatement.first.value_reported)
  end

  it "keeps all retained raw submission hashes intact" do
    metadata = JSON.parse(Rails.root.join("spec/fixtures/13f/unit_transition/filings.json").read)
    metadata.each do |row|
      body = Rails.root.join("spec/fixtures/13f/unit_transition/#{row.fetch('prefix')}_submission.txt").binread
      expect(Digest::SHA256.hexdigest(body)).to eq(row.fetch("submission_sha256"))
    end
  end
end
