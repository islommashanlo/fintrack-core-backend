# frozen_string_literal: true

module Api
  module V1
    class ActivitySerializer
      def initialize(rows:, as_of: Time.current)
        @as_of = as_of
        @owners = InsiderTransaction.where(id: rows.flat_map { |row| row.fetch("reporting_owner_ids") })
          .includes(:filing).index_by(&:id)
        report_ids = rows.flat_map { |row| row.fetch("context_report_ids") }
        @reports = InstitutionalReport.where(id: report_ids).includes(:filing, :institutional_filer).index_by(&:id)
        @filings = @owners.values.to_h { |owner| [ owner.filing_id, owner.filing ] }
          .merge(@reports.values.to_h { |report| [ report.filing_id, report.filing ] })
      end

      def render(row)
        source = row.fetch("source")
        transaction = @owners.fetch(row.fetch("source_id")) if source == "insider"
        filing = @filings.fetch(row.fetch("primary_filing_id"))
        FilingProvenance.render(filing, as_of: @as_of).merge(
          id: ActivityIdentifier.encode(row), source:, occurred_at: row.fetch("occurred_at"),
          period_of_report: row["period_of_report"], direction: row.fetch("direction"),
          activity_type: row.fetch("activity_type"), value: row["value"], score: nil, level: nil,
          reasons: [], score_breakdown: [], sector: nil,
          transaction: transaction && InsiderTransactionSerializer.render(transaction, as_of: @as_of),
          reporting_owners: row.fetch("reporting_owner_ids").map do |id|
            InsiderTransactionSerializer.render(@owners.fetch(id), as_of: @as_of).slice(:insider_cik, :insider_name, :role)
          end,
          fund: source == "institutional" ? fund(row) : nil,
          issuer: transaction ? { cik: transaction.issuer_cik, name: filing.issuer_name, ticker: row["ticker"] } :
            { cik: nil, name: position_data(row)["name_of_issuer"], ticker: row["ticker"] },
          position_change: source == "institutional" ? position_change(row) : nil
        )
      end

      private

      def fund(row)
        report = @reports.fetch(row.fetch("context_report_ids").first)
        { cik: row.fetch("fund_cik"), name: report.institutional_filer.name }
      end

      def position_data(row)
        value = row.fetch("position_data")
        value.is_a?(String) ? JSON.parse(value) : value
      end

      def position_change(row)
        data = position_data(row)
        data.except("name_of_issuer").merge("issuer_name" => data["name_of_issuer"],
          "change_type" => PositionChangeSerializer::CHANGE_TYPES.fetch(data.fetch("change_type")),
          "current_sources" => sources(row.fetch("current_report_ids")), "prior_sources" => sources(row.fetch("prior_report_ids")),
          "comparison_sources" => sources(row.fetch("context_report_ids")))
      end

      def sources(ids)
        ids.map { |id| FilingProvenance.render(@reports.fetch(id).filing, as_of: @as_of) }
      end
    end
  end
end
