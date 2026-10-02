# frozen_string_literal: true

require "rails_helper"

RSpec.describe ParseForm13fJob do
  let(:accession_no) { "0002135539-26-000001" }
  let!(:filing) do
    create(
      :filing, :pending, accession_no:, cik: "0002135539", form_type: "13F-HR",
      filed_on: Date.new(2026, 5, 15), filed_at: Time.utc(2026, 5, 15, 20, 0),
      period_of_report: Date.new(2026, 3, 31)
    )
  end
  let(:base_url) { "https://www.sec.gov/Archives/edgar/data/2135539/000213553926000001" }
  let(:index_url) { "#{base_url}/index.html" }
  let(:cover_url) { "#{base_url}/primary_document.xml" }
  let(:information_url) { "#{base_url}/holdings_v3.xml" }
  let(:index_body) do
    <<~HTML
      <table>
        <tr><td><a href="primary_document.xml">primary_document.xml</a></td><td>13F-HR</td><td>13F HOLDINGS REPORT</td></tr>
        <tr><td><a href="holdings_v3.xml">holdings_v3.xml</a></td><td>EX-99.1</td><td>INFORMATION TABLE</td></tr>
      </table>
    HTML
  end

  def stub_filing(**response)
    stub_request(:get, index_url).to_return(status: 200, body: index_body)
    stub_request(:get, cover_url).to_return(status: 200, body: form13f_cover(:recent_2026_q1))
    stub_request(:get, information_url).to_return(**response)
  end

  it "fetches, archives, parses and ingests through three SecClient requests" do
    request = stub_filing(status: 200, body: form13f_information(:recent_2026_q1))

    described_class.perform_now(accession_no, value_unit: "whole_dollars")

    expect(request).to have_been_requested.once
    report = InstitutionalReport.sole
    expect(report).to have_attributes(status: "parsed", table_entry_total: 146, suspect: false)
    expect(report.information_raw_path).to eq(
      "13f/0002135539/2026/0002135539-26-000001/holdings_v3.xml"
    )
    expect(InstitutionalHolding.count).to eq(146)
    expect(filing.reload.parse_status).to eq("parsed")
    expect(EvaluateAlertsJob).to have_been_enqueued.with(filing.id)
  end

  it "reprocesses from the two archived XML documents without asking the SEC again" do
    requests = stub_filing(status: 200, body: form13f_information(:recent_2026_q1))
    described_class.perform_now(accession_no, value_unit: "whole_dollars")

    described_class.perform_now(accession_no, value_unit: "whole_dollars")

    expect(a_request(:get, index_url)).to have_been_requested.once
    expect(a_request(:get, cover_url)).to have_been_requested.once
    expect(requests).to have_been_requested.once
    expect(InstitutionalHolding.count).to eq(146)
  end

  it "records deterministic parser errors without retrying" do
    stub_filing(status: 200, body: form13f_information(:recent_2026_q1).sub("</ns1:informationTable>", ""))

    described_class.perform_now(accession_no, value_unit: "whole_dollars")

    expect(ParseFailure.sole).to have_attributes(accession_no:, attempts: 1, error: /Form13fInformationTableParser::MalformedError/)
    expect(filing.reload.parse_status).to eq("failed")
    expect(described_class).not_to have_been_enqueued
  end

  it "retries transient SEC failures at most three times" do
    stub_request(:get, index_url).to_return(status: 500)

    perform_enqueued_jobs { described_class.perform_later(accession_no, value_unit: "whole_dollars") }

    expect(a_request(:get, index_url)).to have_been_requested.times(4)
    expect(ParseFailure.sole).to have_attributes(error: /SecClient::TransientError/, attempts: 1)
    expect(filing.reload.parse_status).to eq("failed")
  end

  it "records a 13F-NT with only the cover request after index discovery" do
    accession = "0002124041-26-000002"
    nt = create(
      :filing, :pending, accession_no: accession, cik: "0002124041", form_type: "13F-NT",
      filed_on: Date.new(2026, 5, 15), filed_at: Time.utc(2026, 5, 15, 20, 0),
      period_of_report: Date.new(2026, 3, 31)
    )
    nt_index = "https://www.sec.gov/Archives/edgar/data/2124041/000212404126000002/index.html"
    nt_cover = "https://www.sec.gov/Archives/edgar/data/2124041/000212404126000002/notice.xml"
    stub_request(:get, nt_index).to_return(
      status: 200,
      body: '<table><tr><td><a href="notice.xml">notice.xml</a></td><td>13F-NT</td><td>13F NOTICE</td></tr></table>'
    )
    stub_request(:get, nt_cover).to_return(status: 200, body: form13f_cover(:notice_2026_q1))

    described_class.perform_now(accession, value_unit: nil)

    expect(nt.reload.parse_status).to eq("parsed")
    expect(InstitutionalReport.find_by!(filing: nt)).to have_attributes(status: "parsed")
    expect(InstitutionalHolding.where(institutional_report: InstitutionalReport.find_by!(filing: nt))).to be_empty
  end

  it "skips a pre-XML directory without recording a parse failure" do
    old = create(
      :filing, :pending, accession_no: "0000000123-99-000001", cik: "0000000123", form_type: "13F-HR",
      filed_on: Date.new(1999, 11, 15), filed_at: Time.utc(1999, 11, 15, 20, 0),
      period_of_report: Date.new(1999, 9, 30)
    )
    old_index = "https://www.sec.gov/Archives/edgar/data/123/000000012399000001/index.html"
    stub_request(:get, old_index).to_return(
      status: 200,
      body: '<table><tr><td><a href="0000000123-99-000001.txt">submission</a></td><td>13F-HR</td></tr></table>'
    )

    described_class.perform_now(old.accession_no)

    expect(old.reload.parse_status).to eq("parsed")
    expect(InstitutionalReport.find_by!(filing: old)).to have_attributes(status: "skipped")
    expect(ParseFailure.count).to eq(0)
  end
end
