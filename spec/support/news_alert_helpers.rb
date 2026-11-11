# frozen_string_literal: true

module NewsAlertHelpers
  def news_rule(user:, entity:, conditions: {}, frequency: "daily_digest", ticker: "ACME")
    type, key = case entity.role
    when "fund" then [ "InstitutionalFiler", InstitutionalFiler.find(entity.id).cik ]
    when "person" then [ "Insider", Filer.find(entity.id).cik ]
    else [ "Ticker", ticker ]
    end
    follow = create(:follow, user:, target_type: type, target_key: key, followed_at: 1.year.ago, skip_default_alert_rule: true)
    rule = AlertRuleControl.create(user:, follow_id: follow.id,
      attributes: { event_type: "news", conditions: NewsAlertConditions.normalize(conditions) }).rule
    enable_rule(rule, frequency:)
  end
end

RSpec.configure { |config| config.include NewsAlertHelpers }
