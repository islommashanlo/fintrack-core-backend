# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "api:validate_contract" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("api:validate_contract") }
  let(:task) { Rake::Task["api:validate_contract"].tap(&:reenable) }

  it "prints the verified operation count" do
    count = ApiContract::Check.new.call.operation_count
    expect { task.invoke }.to output(/API contract valid: #{count} operations/).to_stdout
  end

  it "exits unsuccessfully with actionable contract errors" do
    result = ApiContract::Check::Result.new(errors: [ "Unrouted operation: GET /api/v1/missing" ], operation_count: 1)
    allow(ApiContract::Check).to receive(:new).and_return(instance_double(ApiContract::Check, call: result))
    expect do
      expect { task.invoke }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end.to output(/Unrouted operation: GET \/api\/v1\/missing/).to_stderr
  end
end
