# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form13fBackfill do
  PlanIndex = Struct.new(:refs_by_day) do
    def available?(_day)
      true
    end

    def fetch(day)
      refs_by_day.fetch(day, [])
    end
  end

  let(:day) { Date.new(2026, 9, 30) }
  let(:refs) do
    [
      Edgar::FilingRef.new(accession_no: "0002135539-26-000001", cik: "0002135539", form_type: "13F-HR", filed_on: day),
      Edgar::FilingRef.new(accession_no: "0002124041-26-000002", cik: "0002124041", form_type: "13F-NT", filed_on: day)
    ]
  end

  it "counts document requests without registering or queuing filings" do
    plan = described_class.new(index: PlanIndex.new({ day => refs })).plan(from: day, to: day)

    expect(plan).to have_attributes(discovery_requests: 0, document_requests: 5, request_count: 5)
    expect(plan.refs.map(&:accession_no)).to contain_exactly(*refs.map(&:accession_no))
    expect(Filing.count).to eq(0)
    expect(enqueued_jobs).to be_empty
  end

  it "requires an explicit unit when the filing date is missing" do
    refs[0] = refs.first.with(filed_on: nil)
    plan = described_class.new(index: PlanIndex.new({ day => refs })).plan(from: day, to: day)

    expect { described_class.new.execute(plan, value_unit: nil) }
      .to raise_error(ArgumentError, /value_unit is required/)
  end

  it "registers 13F refs and queues the approved unit when confirmed" do
    plan = described_class.new(index: PlanIndex.new({ day => refs })).plan(from: day, to: day)

    runs = described_class.new.execute(plan, value_unit: "whole_dollars")

    expect(runs.sole).to have_attributes(status: "done", filings_found: 2, filings_new: 2)
    expect(ParseForm13fBackfillJob).to have_been_enqueued.exactly(2).times
    expect(enqueued_jobs.map { |job| job["arguments"].last }).to all(include("value_unit" => "whole_dollars"))
  end
  it "queues separate units for a mixed-era plan instead of broadcasting a blanket unit" do
    old = Edgar::FilingRef.new(accession_no: "0001172661-22-002493", cik: "0001508097", form_type: "13F-HR", filed_on: Date.new(2022, 11, 14))
    both = [ old, refs.first ]
    plan = described_class.new(index: PlanIndex.new({ day => both })).plan(from: day, to: day)
    expect { described_class.new.execute(plan, value_unit: "whole_dollars") }.to raise_error(ArgumentError, /per-accession/)
    expect(Filing.count).to eq(0)
    described_class.new.execute(plan)
    expect(ParseForm13fBackfillJob).to have_been_enqueued.with(old.accession_no, value_unit: "thousands")
    expect(ParseForm13fBackfillJob).to have_been_enqueued.with(refs.first.accession_no, value_unit: "whole_dollars")
  end

  it "validates every accession before creating runs or registering filings" do
    refs[0] = refs.first.with(filed_on: nil)
    plan = described_class.new(index: PlanIndex.new({ day => refs })).plan(from: day, to: day)
    expect { described_class.new.execute(plan, value_units: {}) }.to raise_error(ArgumentError)
    expect(Filing.count).to eq(0)
    expect(BackfillRun.count).to eq(0)
    expect(enqueued_jobs).to be_empty
  end
end
