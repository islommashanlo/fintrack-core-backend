# frozen_string_literal: true

namespace :alerts do
  desc "Show local legacy-rule conversion counts; CONFIRM=convert pauses Free instant rules"
  task migrate_settings: :environment do
    puts "Legacy alert settings: #{LegacyAlertSettings.counts.to_json}"
    if ENV["CONFIRM"] == "convert"
      abort "This task is limited to development/test" unless Rails.env.development? || Rails.env.test?
      LegacyAlertSettings.convert!
      puts "Conversion complete: #{LegacyAlertSettings.counts.to_json}"
    else
      puts "Dry run only. Set CONFIRM=convert to apply the approved local conversion. No filings or delivery history are changed."
    end
  end
end
