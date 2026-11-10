# frozen_string_literal: true

module Api
  module V1
    class InsiderTransactionSerializer
      def self.render(transaction, as_of: Time.current)
        filing = transaction.filing
        {
          id: transaction.id,
          accession: transaction.accession_no,
          form_type: filing.form_type,
          insider_cik: transaction.insider_cik,
          insider_name: transaction.insider_name,
          issuer: { cik: transaction.issuer_cik, name: filing.issuer_name, ticker: transaction.issuer_ticker },
          role: {
            is_director: transaction.is_director, is_officer: transaction.is_officer,
            is_ten_percent_owner: transaction.is_ten_percent_owner, is_other: transaction.is_other,
            officer_title: transaction.officer_title
          },
          owner_sequence: transaction.owner_seq,
          security_table: transaction.security_table,
          transaction_sequence: transaction.txn_seq,
          security_title: transaction.security_title,
          transaction_date: transaction.transaction_date,
          transaction_code: transaction.transaction_code,
          activity_type: transaction.open_market? ? "open_market" : "administrative",
          direction: transaction.direction,
          shares: transaction.shares,
          price: transaction.price,
          price_suspect: transaction.price_suspect,
          price_suspect_reason: transaction.price_suspect_reason,
          value: transaction.reported_value,
          shares_owned_following: transaction.shares_owned_following,
          acquired_disposed: transaction.acquired_disposed,
          direct_or_indirect: transaction.direct_or_indirect,
          filed_at: filing.filed_at,
          accepted_at: filing.accepted_at,
          ingested_at: filing.ingested_at,
          period_of_report: filing.period_of_report,
          data_age_days: filing.data_age_days(as_of:),
          sec_url: filing.sec_url
        }
      end
    end
  end
end
