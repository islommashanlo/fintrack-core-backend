# frozen_string_literal: true

module Api
  module V1
    class FilingSerializer
      def self.render(filing, as_of: Time.current)
        new(filing, as_of:).render
      end

      def initialize(filing, as_of:)
        @filing = filing
        @as_of = as_of
      end

      def render
        {
          accession: @filing.accession_no,
          form_type: @filing.form_type,
          filer_cik: @filing.cik,
          issuer: issuer,
          filed_at: @filing.filed_at,
          accepted_at: @filing.accepted_at,
          ingested_at: @filing.ingested_at,
          period_of_report: @filing.period_of_report,
          sec_url: @filing.sec_url,
          data_age_days: @filing.data_age_days(as_of: @as_of),
          parse_status: @filing.parse_status,
          amendment: amendment,
          transactions: transactions,
          holdings: holdings
        }
      end

      private

      def issuer
        {
          cik: @filing.issuer_cik,
          name: @filing.issuer_name,
          ticker: @filing.issuer_ticker
        }
      end

      def amendment
        {
          is_amendment: @filing.amendment?,
          amends_accession: @filing.amends_accession_no,
          superseded_by: @filing.superseded_by_accession_no
        }
      end

      def transactions
        @filing.insider_transactions.order(:security_table, :owner_seq, :txn_seq).map do |transaction|
          {
            accession: transaction.accession_no,
            insider_cik: transaction.insider_cik,
            insider_name: transaction.insider_name,
            owner_sequence: transaction.owner_seq,
            security_table: transaction.security_table,
            transaction_sequence: transaction.txn_seq,
            security_title: transaction.security_title,
            transaction_date: transaction.transaction_date,
            transaction_code: transaction.transaction_code,
            activity_type: transaction.open_market? ? "open_market" : "administrative",
            direction: direction(transaction.transaction_code),
            shares: transaction.shares,
            price: transaction.price,
            price_suspect: transaction.price_suspect,
            shares_owned_following: transaction.shares_owned_following,
            direct_or_indirect: transaction.direct_or_indirect,
            sec_url: @filing.sec_url
          }
        end
      end

      def holdings
        report = @filing.institutional_report
        return [] unless report

        report.institutional_holdings.order(:row_seq).map do |holding|
          {
            row_sequence: holding.row_seq,
            cusip: holding.cusip,
            figi: holding.figi,
            issuer_name: holding.name_of_issuer,
            title_of_class: holding.title_of_class,
            value_reported: holding.value_reported,
            value_unit: holding.value_unit,
            value_usd: holding.value_usd,
            shares: holding.shares,
            share_type: holding.share_type,
            put_call: holding.put_call,
            investment_discretion: holding.investment_discretion,
            other_manager: holding.other_manager,
            voting_authority: {
              sole: holding.voting_sole,
              shared: holding.voting_shared,
              none: holding.voting_none
            },
            suspect: holding.suspect,
            sec_url: @filing.sec_url
          }
        end
      end

      def direction(code)
        return "purchase" if code == "P"
        return "sale" if code == "S"

        "other"
      end
    end
  end
end
