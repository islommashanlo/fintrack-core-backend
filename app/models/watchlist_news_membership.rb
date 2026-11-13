# frozen_string_literal: true

class WatchlistNewsMembership < ApplicationRecord
  include WatchlistMembershipSummaries
  DESTINATIONS = WatchlistFilingMembership::DESTINATIONS

  belongs_to :in_app_notification, optional: true
  belongs_to :alert_delivery, optional: true
  belongs_to :alert_rule
  belongs_to :user
  belongs_to :follow
  belongs_to :news_item
  belongs_to :news_alert_snapshot

  def readonly?
    persisted?
  end

  def self.pending_sql(channel: "in_app", as_of: Time.current)
    "EXISTS (#{NewsAlertValidity.watchlist_sources(channel:, as_of:, pending: true)})"
  end
end
