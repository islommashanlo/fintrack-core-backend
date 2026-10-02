# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form13fCoverParser do
  it "parses every committed cover fixture" do
    documents = Filing13fFixtures::COVER_FIXTURES.to_h do |name|
      [ name, described_class.parse(form13f_cover(name)) ]
    end

    expect(documents.values).to all(be_a(Form13fCoverParser::Cover))
    expect(documents[:recent_2026_q1]).to have_attributes(
      submission_type: "13F-HR", period_of_report: Date.new(2026, 3, 31), is_amendment: false,
      report_type: "13F HOLDINGS REPORT", other_included_managers_count: 0,
      table_entry_total: 146, table_value_total: BigDecimal("131295241")
    )
    expect(documents[:recent_2026_q1].filer).to have_attributes(
      cik: "0002135539", name: "SIMA Wealth Partners, LLC", form13f_file_number: "028-26979"
    )
  end

  it "reads amendment metadata and both manager lists from a combination report" do
    amendment = described_class.parse(form13f_cover(:amendment_2026_q1))
    combination = described_class.parse(form13f_cover(:post_cutoff_2023_q1))

    expect(amendment).to have_attributes(
      submission_type: "13F-HR/A", is_amendment: true, amendment_type: "NEW HOLDINGS"
    )
    expect(combination.other_managers.length).to eq(5)
    expect(combination.included_managers.map(&:sequence_no)).to eq([ 1, 2 ])
    expect(combination.included_managers.last).to have_attributes(
      cik: "0001785043", name: "Half Moon Capital, LLC"
    )
    expect(combination.included_managers.first.cik).to be_nil
  end

  it "keeps a notice's missing summary values and information table seam explicit" do
    notice = described_class.parse(form13f_cover(:notice_2026_q1))

    expect(notice).to have_attributes(
      submission_type: "13F-NT", report_type: "13F NOTICE", period_of_report: Date.new(2026, 3, 31),
      table_entry_total: nil, table_value_total: nil
    )
    expect(notice.filer).to have_attributes(cik: "0002124041", name: "LY Corporation")
  end

  describe "malformed input" do
    let(:xml) { form13f_cover(:recent_2026_q1) }

    it "raises its deterministic parser error" do
      {
        "" => /empty document/,
        "<edgarSubmission><headerData>" => /invalid XML/,
        "<somethingElse/>" => /not edgarSubmission/,
        xml.sub("<periodOfReport>03-31-2026</periodOfReport>", "") => /missing headerData\/filerInfo\/periodOfReport/,
        xml.sub("<tableValueTotal>131295241</tableValueTotal>", "<tableValueTotal>many</tableValueTotal>") => /tableValueTotal is not a number/,
        xml.sub("<cik>0002135539</cik>", "<cik>not-a-cik</cik>") => /not a CIK/
      }.each do |input, message|
        expect { described_class.parse(input) }.to raise_error(described_class::MalformedError, message)
      end
    end
  end

  it "is pure: parsing touches neither the database nor the network" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }

    Filing13fFixtures::COVER_FIXTURES.each { |name| described_class.parse(form13f_cover(name)) }

    expect(queries).to be_empty
    expect(a_request(:any, //)).not_to have_been_made
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
