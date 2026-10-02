# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form13fDirectoryIndex do
  let(:html) do
    <<~HTML
      <html><body><table>
        <tr><td><a href="primary_document.xml">primary_document.xml</a></td><td>13F-HR</td><td>13F HOLDINGS REPORT</td></tr>
        <tr><td><a href="holdings_v3.xml">holdings_v3.xml</a></td><td>EX-99.1</td><td>INFORMATION TABLE</td></tr>
      </table></body></html>
    HTML
  end

  it "selects documents by filing-index descriptions even when filenames vary" do
    index = described_class.parse(html)

    expect(index.cover.filename).to eq("primary_document.xml")
    expect(index.information_table.filename).to eq("holdings_v3.xml")
  end

  it "accepts a structured index response" do
    body = {
      "documents" => [
        { "filename" => "cover.xml", "description" => "13F-NT COVER PAGE" }
      ]
    }.to_json

    index = described_class.parse(body)

    expect(index.cover.filename).to eq("cover.xml")
    expect(index.information_table).to be_nil
  end

  it "resolves the remaining XML document when SEC rows omit descriptions" do
    body = <<~HTML
      <html><body><table>
        <tr><td><a href="0002012383-26-001841-index.html">0002012383-26-001841-index.html</a></td><td>2026-05-13</td></tr>
        <tr><td><a href="form13fInfoTable.xml">form13fInfoTable.xml</a></td><td>2331413</td><td>2026-05-13</td></tr>
        <tr><td><a href="primary_doc.xml">primary_doc.xml</a></td><td>13828</td><td>2026-05-13</td></tr>
      </table></body></html>
    HTML

    index = described_class.parse(body)

    expect(index.cover.filename).to eq("primary_doc.xml")
    expect(index.information_table.filename).to eq("form13fInfoTable.xml")
  end

  it "rejects an ambiguous or malformed index deterministically" do
    expect { described_class.parse("<html><body>no documents</body></html>").cover }
      .to raise_error(Form13fDirectoryIndex::MalformedError)
    expect do
      described_class.parse(
        <<~HTML
          <table>
            <tr><td><a href="a.xml">a.xml</a></td><td>13F-HR</td></tr>
            <tr><td><a href="b.xml">b.xml</a></td><td>13F-HR</td></tr>
          </table>
        HTML
      ).cover
    end.to raise_error(Form13fDirectoryIndex::MalformedError)
  end
end
