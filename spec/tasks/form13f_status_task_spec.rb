# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "13F backfill status task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("backfill:13f_status")
  end

  it "reports 13F parse progress separately from Form 4" do
    BackfillRun.create!(day: Date.new(2026, 9, 30), status: "done", filings_found: 2, filings_new: 2)
    create(:filing, form_type: "13F-HR", filed_on: Date.new(2026, 9, 30), parse_status: "parsed")
    create(:filing, form_type: "13F-NT", filed_on: Date.new(2026, 9, 30), parse_status: "pending")

    task = Rake::Task["backfill:13f_status"]
    task.reenable
    output = StringIO.new
    $stdout = output
    task.invoke

    expect(output.string).to include("2026-09-30", "All 13F filings: 1 parsed, 1 pending")
  ensure
    $stdout = STDOUT
  end
end
