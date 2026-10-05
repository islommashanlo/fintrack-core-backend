# frozen_string_literal: true

namespace :policy do
  desc "Fail when policy-scanned product text contains banned recommendation language"
  task banned_terms: :environment do
    violations = Policy::BannedLanguageScan.new.violations
    if violations.empty?
      puts "No banned recommendation language found."
    else
      violations.each do |violation|
        warn "#{violation.path}:#{violation.line}: #{violation.text}"
      end
      abort "Banned recommendation language detected."
    end
  end
end
