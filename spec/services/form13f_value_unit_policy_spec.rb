# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form13fValueUnitPolicy do
  let(:old_accession) { "0001172661-22-002493" }
  let(:new_accession) { "0001965819-23-000005" }

  it "requires the official filing date when no accession assignment exists" do
    expect(described_class.load.unit_for(old_accession)).to eq("unresolved")
    expect(described_class.load.unit_for(new_accession)).to eq("unresolved")
  end

  it "applies independently reviewed accession assignments to both stored real fixture eras" do
    policy = described_class.new(assignments: {
      old_accession => { "value_unit" => "thousands", "evidence" => "Test assignment: pre_cutoff_2022_q3_information.xml:6-10; fixture README" },
      new_accession => { "value_unit" => "whole_dollars", "evidence" => "Test assignment: post_cutoff_2022_q4_information.xml:7-10; fixture README" }
    })
    old = Form13fInformationTableParser.parse(form13f_information(:pre_cutoff_2022_q3)).first
    recent = Form13fInformationTableParser.parse(form13f_information(:post_cutoff_2022_q4)).first
    expect(Form13fValueNormalizer.normalize(value_reported: old.value_reported, value_unit: policy.unit_for(old_accession)).value_usd).to eq(old.value_reported * 1000)
    expect(Form13fValueNormalizer.normalize(value_reported: recent.value_reported, value_unit: policy.unit_for(new_accession)).value_usd).to eq(recent.value_reported)
    expect(policy.unit_for("0002135539-26-000001")).to eq("unresolved")
  end

  [ nil, [], { "bad" => {} }, { "0001172661-22-002493" => { "value_unit" => "thousands", "evidence" => " " } },
    { "0001172661-22-002493" => { "value_unit" => "guessed", "evidence" => "source" } } ].each do |assignments|
    it "rejects malformed or unsupported evidence #{assignments.inspect}" do
      expect { described_class.new(assignments:) }.to raise_error(ArgumentError)
    end
  end
end
