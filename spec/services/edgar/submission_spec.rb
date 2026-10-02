# frozen_string_literal: true

require "rails_helper"

RSpec.describe Edgar::Submission do
  it "reads the header of a real submission" do
    header = described_class.parse(form4_submission(:simple_purchase)).header

    expect(header.accession_no).to eq("0001104659-26-112212")
    expect(header.form_type).to eq("4")
    expect(header.filed_on).to eq(Date.new(2026, 9, 30))
    expect(header.period_of_report).to eq(Date.new(2026, 9, 29))
  end

  it "converts the acceptance time from US Eastern to UTC" do
    # <ACCEPTANCE-DATETIME>20260930113137 is 11:31:37 EDT.
    header = described_class.parse(form4_submission(:simple_purchase)).header

    expect(header.accepted_at).to eq(Time.utc(2026, 9, 30, 15, 31, 37))
  end

  it "handles acceptance times outside daylight saving" do
    text = form4_submission(:simple_purchase).sub("<ACCEPTANCE-DATETIME>20260930113137", "<ACCEPTANCE-DATETIME>20260115093000")

    expect(described_class.parse(text).header.accepted_at).to eq(Time.utc(2026, 1, 15, 14, 30, 0))
  end

  it "reports the amendment form type" do
    expect(described_class.parse(form4_submission(:amendment)).header.form_type).to eq("4/A")
  end

  it "extracts the ownership XML even when the filing carries other documents" do
    xml = described_class.parse(form4_submission(:joint_filers)).ownership_xml

    expect(xml).to start_with("<?xml").and include("<ownershipDocument>").and end_with("</ownershipDocument>")
  end

  it "raises a deterministic error for empty, truncated or XML-less submissions" do
    raw = form4_submission(:simple_purchase)

    expect { described_class.parse("") }.to raise_error(described_class::MalformedError, /empty/)
    expect { described_class.parse(raw[0, 200]).header }.to raise_error(described_class::MalformedError)
    expect { described_class.parse(raw.sub(%r{<XML>.*</XML>}m, "")).ownership_xml }
      .to raise_error(described_class::MalformedError, /no ownership XML/)
  end
end
