# frozen_string_literal: true

require "rails_helper"

RSpec.describe FilingRegistrar do
  let(:refs) { Edgar::DailyIndex.parse(edgar_fixture("master.20260930.idx")) }

  it "records unknown filings as pending and queues each for parsing" do
    added = described_class.register(refs, source: "daily_index")

    expect(added.size).to eq(16)
    expect(Filing.pending.where(source: "daily_index").count).to eq(16)
    expect(Filing.find_by!(accession_no: "0001172508-26-000008")).to have_attributes(
      cik: "0001172508", form_type: "4/A", filed_on: Date.new(2026, 9, 30), filed_at: nil
    )
    expect(enqueued_jobs.map { |job| job["arguments"].first }).to match_array(added)
  end

  it "does nothing the second time, whichever source reports the filing" do
    described_class.register(refs, source: "efts")

    expect { expect(described_class.register(refs, source: "daily_index")).to be_empty }
      .not_to change { [ Filing.count, enqueued_jobs.size ] }
    expect(Filing.distinct.pluck(:source)).to eq([ "efts" ])
  end

  it "leaves a filing that is already parsed alone" do
    known = create(:filing, accession_no: "0001010178-26-000013")

    described_class.register(refs, source: "daily_index")

    expect(known.reload.parse_status).to eq("parsed")
    expect(enqueued_jobs.size).to eq(15)
  end

  it "ignores form types other than 4 and 4/A" do
    other = Edgar::FilingRef.new(accession_no: "0000950103-26-014800", cik: "0001000275", form_type: "424B2",
                                 filed_on: Date.new(2026, 9, 30))

    expect(described_class.register([ other ], source: "daily_index")).to be_empty
    expect(Filing.count).to eq(0)
  end
end
