# frozen_string_literal: true

class InstitutionalAlertMatcher
  SNAPSHOT_FIELDS = %w[event_key institutional_filer_id primary_filing_id period_of_report prior_period_of_report
    cusip put_call share_type name_of_issuer title_of_class change_type shares_before shares_after shares_delta
    value_usd_before value_usd_after value_usd_delta current_suspect prior_suspect values_complete evidence_report_ids].freeze

  def self.call(filing, as_of: Time.current, channel: "email", scope: "follow")
    raise ArgumentError, "Unsupported channel" unless AlertRule::CHANNELS.include?(channel)
    raise ArgumentError, "Unsupported scope" unless AlertRule::SCOPES.include?(scope)
    return [] unless filing&.parse_status == "parsed"
    return [] unless filing.form_type.in?(Filing::FORM13F_TYPES)
    return [] unless AlertRule.active.where(event_type: "13f_change", channel:, scope:).exists?
    report = filing.institutional_report
    return [] unless report&.status == "parsed" && report.submission_type != "13F-NT"
    time = filing.filed_at || report.filed_at
    return [] unless time && time <= as_of
    new(report:, time:, as_of:, channel:, scope:).call
  end

  def initialize(report:, time:, as_of:, channel:, scope:)
    @report, @time, @as_of, @channel, @scope = report, time, as_of, channel, scope
  end

  def call
    matches = Api::V1::CursorPage.sql_rows(matching_sql)
    return [] if matches.empty?
    InstitutionalChangeSnapshot.insert_all(matches.map do |row|
      attributes = row.slice(*SNAPSHOT_FIELDS).merge("current_report_ids" => row.fetch("current_context_ids"),
        "prior_report_ids" => row.fetch("prior_context_ids"), "observed_at" => @as_of)
      %w[value_usd_before value_usd_after value_usd_delta].each { |key| attributes[key] = nil } unless row.fetch("values_complete")
      attributes
    end, unique_by: :index_institutional_change_snapshots_on_event_key)
    ids = InstitutionalChangeSnapshot.where(event_key: matches.map { |row| row.fetch("event_key") }).pluck(:event_key, :id).to_h
    matches.map { |row| row.merge("institutional_change_snapshot_id" => ids.fetch(row.fetch("event_key")), "filing_id" => row.fetch("primary_filing_id")) }
  end

  private

  def matching_sql
    changes = InstitutionalAlertChanges.new(report: @report, as_of: @as_of).sql
    sql = ApplicationRecord.sanitize_sql([ <<~SQL, report_id: @report.id, time: @time, cik: @report.institutional_filer.cik, channel: @channel, scope: @scope, now: @as_of ])
      WITH changes AS (INSTITUTIONAL_CHANGES)
      SELECT rules.id, settings.frequency, settings.revision AS rule_revision, rules.user_id, follows.id AS follow_id,
        follows.followed_at, follows.target_type, follows.target_key, preferences.time_zone, changes.*
      FROM follows INNER JOIN alert_rules rules ON #{ @scope == "watchlist" ? "rules.user_id = follows.user_id" : "rules.follow_id = follows.id" }
      INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = rules.id
      LEFT JOIN notification_preferences preferences ON preferences.user_id = rules.user_id
      CROSS JOIN changes
      WHERE rules.scope = :scope AND rules.active AND rules.event_type = '13f_change' AND rules.channel = :channel
        AND follows.target_type = 'InstitutionalFiler' AND follows.target_key = :cik
        AND follows.removed_at IS NULL AND settings.archived_at IS NULL
        AND (:scope <> 'watchlist' OR (
          (settings.frequency = 'instant' OR preferences.time_zone IS NOT NULL)
          AND (:channel <> 'email' OR (preferences.email_enabled AND preferences.email_enabled_at <= :now
            AND preferences.time_zone IS NOT NULL))))
        AND :time >= settings.enabled_at AND :time >= follows.followed_at
        AND :report_id = ANY(changes.evidence_report_ids)
        AND (settings.conditions->'change_types' IS NULL OR settings.conditions->'change_types' @> jsonb_build_array(changes.api_change_type))
        AND (settings.conditions->>'direction' IS NULL OR settings.conditions->>'direction' =
          CASE WHEN changes.change_type IN ('new', 'add') THEN 'increase' ELSE 'decrease' END)
        AND (settings.conditions->>'cusip' IS NULL OR settings.conditions->>'cusip' = changes.cusip)
        AND (settings.conditions->>'put_call' IS NULL OR settings.conditions->>'put_call' = changes.put_call)
        AND (settings.conditions->>'share_type' IS NULL OR settings.conditions->>'share_type' = changes.share_type)
        AND (settings.conditions->>'min_value' IS NULL OR
          (changes.values_complete AND ABS(changes.value_usd_delta) >= (settings.conditions->>'min_value')::numeric))
    SQL
    sql.sub("INSTITUTIONAL_CHANGES") { changes }
  end
end
