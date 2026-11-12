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

  it "archives 13F documents under manager, year, accession and original filename" do
    path = archive.store_13f(
      manager_cik: "2135539", year: 2026, accession_no: "0002135539-26-000001",
      filename: "sima13fq12026.xml", body: form13f_information(:recent_2026_q1)
    )

    expect(path).to eq("13f/0002135539/2026/0002135539-26-000001/sima13fq12026.xml")
    expect(archive.read(path)).to eq(form13f_information(:recent_2026_q1))
  end

  it "keeps 13F archives write-once and rejects unsafe filenames" do
    arguments = {
      manager_cik: "0002135539", year: 2026, accession_no: "0002135539-26-000001", filename: "cover.xml"
    }
    path = archive.store_13f(**arguments, body: "as first served")

    expect(archive.store_13f(**arguments, body: "something else")).to eq(path)
    expect(archive.read(path)).to eq("as first served")
    expect { archive.store_13f(**arguments, filename: "../cover.xml", body: "x") }.to raise_error(ArgumentError)
  end

  it "probes missing, empty and nonempty files without reading bodies" do
    path = archive.store(accession_no, "stored bytes")
    expect(archive.probe(path)).to eq("present")
    expect(archive.probe(nil)).to eq("missing_path")
    expect(archive.probe("missing.txt")).to eq("missing")
    empty = archive.store("0001104659-26-112213", "")
    expect(archive.probe(empty)).to eq("empty")
    expect(archive.probe("0001104659")).to eq("not_file")
    allow(File).to receive(:readable?).and_call_original
    allow(File).to receive(:readable?).with(Pathname(ENV.fetch("FILING_ARCHIVE_ROOT")).realpath.join(path)).and_return(false)
    expect(archive.probe(path)).to eq("unreadable")
    expect(archive.read(path)).to eq("stored bytes")
  end

  it "rejects unsafe and symlinked probe paths, including descendant symlinks" do
    archive.store(accession_no, "stored bytes")
    [ "../outside", "/etc/passwd", "x/../../outside", "x//file", "x/./file", "x\u0000file" ].each do |path|
      expect(archive.probe(path)).to eq("invalid_path")
    end
    root = Pathname(ENV.fetch("FILING_ARCHIVE_ROOT"))
    File.symlink(root.join("0001104659"), root.join("linked"))
    expect(archive.probe("linked/26/#{accession_no}.txt")).to eq("invalid_path")
    File.symlink(root.join("0001104659/26/#{accession_no}.txt"), root.join("linked.txt"))
    expect(archive.probe("linked.txt")).to eq("invalid_path")
  end
end
