# frozen_string_literal: true

module ClusterAlertHelpers
  def cluster_rule(user:, type: "Ticker", key: "ACME", conditions: {}, frequency: "daily_digest")
    follow = create(:follow, user:, target_type: type, target_key: key, followed_at: 1.year.ago, skip_default_alert_rule: true)
    result = AlertRuleControl.create(user:, follow_id: follow.id,
      attributes: { event_type: "cluster", conditions: ClusterAlertConditions.normalize(conditions) })
    enable_rule(result.rule, frequency:)
  end

  def cluster_trade(cik:, at: 1.hour.ago, code: "P", issuer: "0000000123", ticker: "ACME", filing: nil, **attributes)
    filing ||= create(:filing, filed_at: at, issuer_cik: issuer, issuer_ticker: ticker)
    create(:insider_transaction, filing:, insider_cik: cik, transaction_code: code, shares: 10, price: 20, **attributes)
  end

  def cluster_trades(code: "P", **attributes)
    3.times.map { |i| cluster_trade(cik: format("%010d", 901 + i), at: (3 - i).hours.ago, code:, **attributes) }
  end
end
