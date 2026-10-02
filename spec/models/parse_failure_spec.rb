# frozen_string_literal: true

require "rails_helper"

RSpec.describe ParseFailure do
  let(:accession_no) { "0000000001-26-000001" }

  it "keeps one row per filing and counts attempts" do
    described_class.record!(accession_no, ArgumentError.new("first"))
    described_class.record!(accession_no, RuntimeError.new("second"))

    failure = described_class.find_by!(accession_no:)
    expect(described_class.count).to eq(1)
    expect(failure.attempts).to eq(2)
    expect(failure.error).to eq("RuntimeError: second")
    expect(failure.last_failed_at).to be_present
  end

  it "marks a failure resolved without deleting it, and reopens it if the filing fails again" do
    described_class.record!(accession_no, "boom")

    described_class.resolve!(accession_no)
    expect(described_class.unresolved).to be_empty
    expect(described_class.count).to eq(1)

    described_class.record!(accession_no, "boom again")
    expect(described_class.unresolved.pick(:attempts)).to eq(2)
  end
end
