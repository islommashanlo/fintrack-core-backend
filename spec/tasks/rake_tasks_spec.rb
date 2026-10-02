# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "Rake tasks" do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "validate:report" } }

  def run_task(name, *args)
    task = Rake::Task[name]
    task.reenable
    output = StringIO.new
    $stdout = output
    task.invoke(*args)
    output.string
  ensure
    $stdout = STDOUT
  end

  before do
    FilingFixtures::FORM4.each_key { |name| ingest_form4(name).update!(raw_path: "x/26/#{form4_accession(name)}.txt") }
  end

  it "query:recent_purchases lists purchases with the disclaimer" do
    travel_to Time.utc(2026, 10, 2) do
      output = run_task("query:recent_purchases", "7")

      expect(output).to include("ASGI", "Baird Gordon A", "612.16", "0001104659-26-112212")
      expect(output).to end_with("Data from public SEC filings. Not investment advice.\n")
    end
  end

  it "query:cluster_buys and query:top_insiders run" do
    travel_to Time.utc(2026, 10, 2) do
      expect(run_task("query:cluster_buys", "30", "1")).to include("ADRX", "Insiders")
      expect(run_task("query:top_insiders")).to include("Abu Dhabi Investment Authority", "22380356.0116")
    end
  end

  it "validate:report prints every check and succeeds on clean data" do
    output = run_task("validate:report")

    expect(output).to include("INFO  10 Form 4 filings", "PASS  No unresolved parse failures", "0 FAIL")
  end

  it "validate:report exits 1 when a check fails" do
    Filing.first.update!(filed_at: nil)

    expect { run_task("validate:report") }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "backfill:status shows runs and parse progress per day" do
    BackfillRun.create!(day: Date.new(2026, 9, 30), status: "done", filings_found: 300, filings_new: 300)

    output = run_task("backfill:status")

    expect(output).to match(/2026-09-30\s+done\s+300\s+300\s+9\s+0\s+0/)
    expect(output).to include("All Form 4 filings: 10 parsed")
  end

  it "diagnose:prices and diagnose:failures run" do
    InsiderTransaction.first.update!(price: 90_000, price_suspect: true, price_suspect_reason: "over_50k_per_share")
    ParseFailure.record!("0000000001-26-000001", "Form4Parser::MalformedError: invalid XML")

    expect(run_task("diagnose:prices")).to include("over_50k_per_share", "Twenty highest prices")
    expect(run_task("diagnose:failures")).to include("0000000001-26-000001", "invalid XML")
  end

  it "pipeline:retry_failures and pipeline:requeue_pending queue the right filings" do
    Filing.first.update!(parse_status: "failed")
    stuck = create(:filing, :pending, created_at: 2.hours.ago)
    create(:filing, :pending) # fresh; left alone

    expect(run_task("pipeline:retry_failures")).to include("Queued 1 failed filings.")
    expect(run_task("pipeline:requeue_pending")).to include("Queued 1 pending filings.")
    expect(enqueued_jobs.map { |job| job["arguments"].first }).to contain_exactly(Filing.failed.sole.accession_no, stuck.accession_no)
  end
end
