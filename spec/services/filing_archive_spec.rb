# frozen_string_literal: true

require "rails_helper"

RSpec.describe FilingArchive do
  subject(:archive) { described_class.default }

  let(:accession_no) { "0001104659-26-112212" }

  it "stores a filing byte for byte and reads it back" do
    body = form4_submission(:simple_purchase)

    path = archive.store(accession_no, body)

    expect(path).to eq("0001104659/26/0001104659-26-112212.txt")
    expect(archive.exist?(path)).to be(true)
    expect(archive.read(path)).to eq(body)
  end

  it "never replaces a filing that is already archived" do
    path = archive.store(accession_no, "as first served")

    expect(archive.store(accession_no, "something else")).to eq(path)
    expect(archive.read(path)).to eq("as first served")
  end

  it "rejects anything that is not an accession number" do
    [ "../../etc/passwd", "0001104659-26-112212/../x", "", nil ].each do |bad|
      expect { archive.store(bad, "x") }.to raise_error(ArgumentError)
    end
  end

  it "reports missing filings" do
    expect(archive.exist?(nil)).to be(false)
    expect(archive.exist?("0000000001/26/0000000001-26-000001.txt")).to be(false)
    expect { archive.read("0000000001/26/0000000001-26-000001.txt") }.to raise_error(FilingArchive::MissingError)
  end
end
