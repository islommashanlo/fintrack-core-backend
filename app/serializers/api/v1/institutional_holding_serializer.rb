# frozen_string_literal: true

module Api
  module V1
    class InstitutionalHoldingSerializer
      def self.render(holding, as_of: Time.current)
        report = holding.institutional_report
        FilingProvenance.render(report.filing, as_of:).merge(
          id: holding.id, fund: { cik: report.institutional_filer.cik, name: report.institutional_filer.name },
          period_of_report: report.period_of_report, row_sequence: holding.row_seq,
          cusip: holding.cusip, figi: holding.figi, issuer_name: holding.name_of_issuer,
          title_of_class: holding.title_of_class, value_reported: holding.value_reported,
          value_unit: holding.value_unit, value_usd: holding.value_usd,
          shares: holding.shares, share_type: holding.share_type, put_call: holding.put_call,
          investment_discretion: holding.investment_discretion, other_manager: holding.other_manager,
          voting_authority: { sole: holding.voting_sole, shared: holding.voting_shared, none: holding.voting_none },
          suspect: holding.suspect, suspect_reason: holding.suspect_reason
        )
      end
    end
  end
end
