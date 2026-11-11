# frozen_string_literal: true

class NewsAlertText
  def self.subject(target_key)
    key = Policy::BannedLanguageScan.new.scan_text(target_key).empty? ? target_key : "your followed profile"
    "News headline for #{key}"
  end

  def self.render(snapshot)
    "#{snapshot.source} published this headline: #{snapshot.title}"
  end
end
