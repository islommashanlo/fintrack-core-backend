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

  it "requires a unit before executing a holdings backfill" do
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
end
