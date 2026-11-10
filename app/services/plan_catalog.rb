# frozen_string_literal: true

class PlanCatalog
  PLANS = {
    "free" => {
      watchlist_items: 15, alert_rules: 3, instant_alerts: false, unusual_activity_results: 1,
      screener_results: 3, saved_screens: false, fund_compare: 2, history_quarters: 4, csv_export: false
    }.freeze,
    "pro" => {
      watchlist_items: nil, alert_rules: nil, instant_alerts: true, unusual_activity_results: nil,
      screener_results: nil, saved_screens: true, fund_compare: nil, history_quarters: nil, csv_export: true
    }.freeze
  }.freeze

  def self.for_user(_user)
    # Subscription entitlements will come from verified billing records.
    "free"
  end

  def self.limit_for(user, feature)
    PLANS.fetch(for_user(user)).fetch(feature)
  end

  class Required < StandardError
    attr_reader :feature, :limit

    def initialize(feature:, limit:)
      @feature = feature
      @limit = limit
      super("This feature requires Pro")
    end
  end
end
