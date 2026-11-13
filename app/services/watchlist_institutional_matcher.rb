# frozen_string_literal: true

class WatchlistInstitutionalMatcher
  def self.call(filing, channel:, as_of: Time.current)
    matches = InstitutionalAlertMatcher.call(filing, channel:, as_of:, scope: "watchlist")
    trigger_at = filing&.filed_at || filing&.institutional_report&.filed_at
    WatchlistSnapshotCapture.call(matches:, event_type: "13f_change", channel:, trigger_at:, as_of:)
  end
end
