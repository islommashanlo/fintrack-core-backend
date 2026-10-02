# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cron schedule" do
  let(:schedule) { CronSchedule.jobs }

  it "defines valid jobs that point at real job classes" do
    expect(schedule.keys).to contain_exactly("poll_edgar", "reconcile_edgar")

    schedule.each do |name, attributes|
      job = Sidekiq::Cron::Job.new(attributes.merge("name" => name))

      expect(job).to be_valid, "#{name}: #{job.errors.join(', ')}"
      expect(attributes.fetch("class").constantize).to be < ApplicationJob
    end
  end

  it "is a plain string-keyed hash, which is what sidekiq-cron loads" do
    expect(schedule).to be_an_instance_of(Hash)
    expect(schedule.values).to all(be_an_instance_of(Hash))
    expect(schedule.values.flat_map(&:keys)).to all(be_a(String))
  end

  it "polls EDGAR every minute" do
    expect(schedule.dig("poll_edgar", "cron")).to eq("* * * * *")
    expect(schedule.dig("poll_edgar", "class")).to eq("PollEdgarJob")
  end
end
