# frozen_string_literal: true

class WatchlistFilingMembership < ApplicationRecord
  include WatchlistMembershipSummaries
  belongs_to :in_app_notification, optional: true
  belongs_to :alert_delivery, optional: true
  belongs_to :alert_rule
  belongs_to :user
  belongs_to :filing
  belongs_to :follow

  def readonly?
    persisted?
  end

  DESTINATIONS = { "in_app" => [ "in_app_notification_id", "in_app_notifications" ],
    "email" => [ "alert_delivery_id", "alert_deliveries" ] }.freeze

  def self.pending_sql(channel: "in_app")
    column, table = DESTINATIONS.fetch(channel)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM watchlist_filing_memberships witness
        INNER JOIN follows live ON live.id = witness.follow_id AND live.user_id = witness.user_id
        WHERE witness.#{column} = #{table}.id
          AND witness.alert_rule_id = alert_rules.id AND witness.user_id = alert_rules.user_id
          AND witness.filing_id = #{table}.filing_id
          AND live.removed_at IS NULL AND live.followed_at = witness.followed_at
          AND live.target_type = witness.target_type AND live.target_key = witness.target_key
      )
    SQL
  end
end
