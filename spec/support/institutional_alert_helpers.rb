# frozen_string_literal: true

require_relative "institutional_read_helpers"

module InstitutionalAlertHelpers
  include InstitutionalReadHelpers

  def institutional_rule(user:, fund:, conditions: {}, frequency: "daily_digest")
    follow = create(:follow, user:, target_type: "InstitutionalFiler", target_key: fund.cik,
      followed_at: 1.year.ago, skip_default_alert_rule: true)
    result = AlertRuleControl.create(user:, follow_id: follow.id,
      attributes: { event_type: "13f_change", conditions: InstitutionalAlertConditions.normalize(conditions) })
    enable_rule(result.rule, frequency:)
  end

  def alert_report(fund:, period: Date.new(2026, 9, 30), at: 1.hour.ago, **attributes)
    create_13f(fund:, period:, filed_at: at, **attributes)
  end

  def finish_alert_report(report)
    rows = report.institutional_holdings
    report.update!(table_entry_total: rows.count, table_value_total: rows.sum(:value_reported))
    report
  end

  def alert_holding(report, **attributes)
    create(:institutional_holding, institutional_report: report, **attributes)
  end

  def alert_pair(fund:, before: 10, after: 20, **attributes)
    prior = alert_report(fund:, period: Date.new(2026, 6, 30), at: 3.days.ago)
    current = alert_report(fund:)
    alert_holding(prior, shares: before, value_reported: before * 10, value_usd: before * 10, **attributes) if before
    alert_holding(current, shares: after, value_reported: after * 10, value_usd: after * 10, **attributes) if after
    [ finish_alert_report(prior), finish_alert_report(current) ]
  end
end
