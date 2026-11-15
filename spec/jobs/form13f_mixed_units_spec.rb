# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mixed-era 13F ingestion" do
  it "normalizes two real fixture eras independently and replays without changing counts or requesting documents again" do
    examples = [
      [ :pre_cutoff_2022_q3, "0001172661-22-002493", "0001508097", Date.new(2022, 11, 14), "thousands", 1000 ],
      [ :post_cutoff_2022_q4, "0001965819-23-000005", "0001965819", Date.new(2023, 2, 14), "whole_dollars", 1 ]
    ]
    assignments = examples.to_h { |name, accession, _cik, _day, unit, _multiplier| [ accession, { "value_unit" => unit, "evidence" => "Test policy from #{name} fixture inspection; not a transition-date inference" } ] }
    allow(Form13fValueUnitPolicy).to receive(:load).and_return(Form13fValueUnitPolicy.new(assignments:))
    filings = examples.map do |name, accession, cik, day, _unit, _multiplier|
      filing = create(:filing, :pending, accession_no: accession, cik:, form_type: "13F-HR", filed_on: day,
        filed_at: day.to_time.utc + 20.hours)
      base = "https://www.sec.gov/Archives/edgar/data/#{Cik.path_segment(cik)}/#{accession.delete('-')}"
      stub_request(:get, "#{base}/index.html").to_return(body: '<table><tr><td><a href="cover.xml">cover.xml</a></td><td>13F-HR</td></tr><tr><td><a href="table.xml">table.xml</a></td><td>INFORMATION TABLE</td></tr></table>')
      stub_request(:get, "#{base}/cover.xml").to_return(body: form13f_cover(name))
      stub_request(:get, "#{base}/table.xml").to_return(body: form13f_information(name))
      filing
    end
    filings.each { |filing| ParseForm13fJob.perform_now(filing.accession_no) }
    expect(ParseFailure.count).to eq(0)
    examples.zip(filings).each do |(name, _accession, _cik, _day, unit, multiplier), filing|
      raw = Form13fInformationTableParser.parse(form13f_information(name)).first.value_reported
      expect(filing.reload.institutional_report.cover_value_unit).to eq(unit)
      expect(filing.institutional_report.institutional_holdings.order(:row_seq).first)
        .to have_attributes(value_reported: raw, value_unit: unit, value_usd: raw * multiplier)
    end
    counts = [ InstitutionalReport.count, InstitutionalHolding.count ]
    filings.each { |filing| ParseForm13fJob.perform_now(filing.accession_no) }
    expect([ InstitutionalReport.count, InstitutionalHolding.count ]).to eq(counts)
    expect(a_request(:get, %r{https://www\.sec\.gov/Archives/.*})).to have_been_requested.times(6)
  end
end
