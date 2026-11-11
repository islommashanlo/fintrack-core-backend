# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "Sidekiq server initialization" do
  it "loads notification worker configuration before Rails finishes autoload setup" do
    script = <<~RUBY
      require "sidekiq/cli"
      require #{Rails.root.join('config/environment').to_s.inspect}
      config = Sidekiq.default_configuration
      raise "missing notification pool" unless config.capsules.fetch("notifications").concurrency == 2
      raise "SEC polling unexpectedly enabled" unless CronSchedule.jobs.keys == ["alert_digests"]
      puts "server configuration booted"
    RUBY
    stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "test", "EDGAR_POLLING" => "off" }, RbConfig.ruby, "-e", script)
    expect(status).to be_success, stderr
    expect(stdout).to include("server configuration booted")
  end
end
