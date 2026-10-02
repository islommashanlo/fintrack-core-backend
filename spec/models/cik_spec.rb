# frozen_string_literal: true

require "rails_helper"

RSpec.describe Cik do
  it "pads to the ten-digit form EDGAR uses in filings" do
    expect(described_class.normalize("1010178")).to eq("0001010178")
    expect(described_class.normalize(60086)).to eq("0000060086")
    expect(described_class.normalize("0001010178")).to eq("0001010178")
  end

  it "gives the unpadded form used in archive paths" do
    expect(described_class.path_segment("0001010178")).to eq("1010178")
  end

  it "rejects values that are not CIKs" do
    expect { described_class.normalize("abc") }.to raise_error(ArgumentError)
    expect { described_class.normalize("") }.to raise_error(ArgumentError)
    expect { described_class.normalize("12345678901") }.to raise_error(ArgumentError)
  end
end
