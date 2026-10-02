# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "13F rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("backfill:13f")
  end

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

  it "defaults the 13F backfill to a dry run" do
    plan = instance_double(Form13fBackfill::Plan, refs: [], request_count: 7, discovery_requests: 2, document_requests: 5)
    backfill = instance_double(Form13fBackfill)
    allow(Form13fBackfill).to receive(:new).and_return(backfill)
    allow(backfill).to receive(:plan).and_return(plan)
    allow(backfill).to receive(:execute)

    output = run_task("backfill:13f", "2026-01-01", "2026-03-31")

    expect(output).to include("7 SEC requests planned", "2 discovery", "5 document")
    expect(backfill).not_to have_received(:execute)
  end

  it "prints the PASS/FAIL report through validate13f:report" do
    output = run_task("validate13f:report")

    expect(output).to include("institutional reports", "PASS", "0 FAIL")
  end
end
