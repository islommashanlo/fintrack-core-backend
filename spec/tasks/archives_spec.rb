# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "archives:verify" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("archives:verify") }
  let(:task) { Rake::Task["archives:verify"].tap(&:reenable) }

  it "prints PASS for a nonempty archived file without changing stored values or issuing requests" do
    filing = create(:filing)
    filing.update!(raw_path: FilingArchive.default.store(filing.accession_no, "original bytes"))
    counts = [ Filing.count, ParseFailure.count, InstitutionalReport.count ]
    expect { task.invoke("1") }.to output(/PASS.*submission: present.*"checked_documents":1/m).to_stdout
    expect([ Filing.count, ParseFailure.count, InstitutionalReport.count ]).to eq(counts)
    expect(FilingArchive.default.read(filing.reload.raw_path)).to eq("original bytes")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "fails on missing documents while printing bounded continuation and status metadata" do
    first = create(:filing)
    create(:filing)
    expect do
      expect { task.invoke("1") }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end.to output(/FAIL.*missing_path.*"has_more":true.*"next_after_id":#{first.id}/m).to_stdout
  end

  it "rejects invalid limits before scanning" do
    expect do
      expect { task.invoke("501") }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end.to output(/limit must be between 1 and 500/).to_stderr
  end
end
