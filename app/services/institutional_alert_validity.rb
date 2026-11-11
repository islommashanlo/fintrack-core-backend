# frozen_string_literal: true

class InstitutionalAlertValidity
  def self.apply(scope, as_of:)
    reports = InstitutionalReportScope.new(as_of:)
    effective = reports.effective_reports.to_sql
    scope.where(<<~SQL.squish)
      alert_deliveries.institutional_change_snapshot_id IS NULL OR EXISTS (
        SELECT 1 FROM institutional_change_snapshots snapshot
        WHERE snapshot.id = alert_deliveries.institutional_change_snapshot_id
          AND snapshot.current_report_ids = ARRAY(SELECT r.id FROM (#{effective}) r
            WHERE r.institutional_filer_id = snapshot.institutional_filer_id AND r.period_of_report = snapshot.period_of_report ORDER BY r.id)
          AND snapshot.prior_report_ids = ARRAY(SELECT r.id FROM (#{effective}) r
            WHERE r.institutional_filer_id = snapshot.institutional_filer_id AND r.period_of_report = snapshot.prior_period_of_report ORDER BY r.id)
          AND NOT EXISTS (SELECT 1 FROM unnest(snapshot.evidence_report_ids) sources(id)
            WHERE sources.id NOT IN (SELECT visible.id FROM (#{reports.visible_reports.to_sql}) visible))
      )
    SQL
  end
end
