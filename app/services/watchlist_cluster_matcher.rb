# frozen_string_literal: true

class WatchlistClusterMatcher
  def self.call(filing, channel:, as_of: Time.current)
    matches = ClusterAlertMatcher.call(filing, channel:, as_of:, scope: "watchlist")
    WatchlistSnapshotCapture.call(matches:, event_type: "cluster", channel:, trigger_at: filing&.filed_at, as_of:)
  end
end
