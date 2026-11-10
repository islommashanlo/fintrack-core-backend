# frozen_string_literal: true

module Api
  module V1
    class InstitutionalReportSerializer
      def self.render(report, as_of: Time.current)
        FilingProvenance.render(report.filing, as_of:).merge(
          id: report.id, period_of_report: report.period_of_report,
          report_type: report.report_type, amendment_type: report.amendment_type,
          amendment_number: report.amendment_number,
          other_manager_count: report.other_included_managers_count,
          table_entry_total: report.table_entry_total, table_value_total: report.table_value_total,
          value_unit: report.cover_value_unit, suspect: report.suspect, suspect_reason: report.suspect_reason
        )
      end
    end
  end
end
