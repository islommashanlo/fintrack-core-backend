# frozen_string_literal: true

module Api
  module V1
    class InsiderClusterSerializer
      def initialize(rows:, as_of: Time.current)
        @as_of = as_of
        @filings = Filing.where(id: rows.flat_map { |row| row.fetch("filing_ids") }).index_by(&:id)
      end

      def render(row)
        filing = @filings.fetch(row.fetch("primary_filing_id"))
        FilingProvenance.render(filing, as_of: @as_of).merge(
          id: "cluster_#{row.fetch('event_key')}",
          issuer: { cik: row.fetch("issuer_cik"), name: row["issuer_name"], ticker: row["issuer_ticker"] },
          direction: row.fetch("transaction_code") == "P" ? "purchase" : "sale",
          window_start: row.fetch("window_start"), window_end: row.fetch("window_end"), window_days: ActivityMethodology.window_days,
          insider_count: row.fetch("insider_count"), transaction_count: row.fetch("transaction_count"),
          total_value: row["total_value"], known_value_subtotal: row["known_value_subtotal"],
          transactions_without_usable_price: row.fetch("transactions_without_usable_price"),
          transaction_ids: row.fetch("transaction_ids"), activity_ids: row.fetch("transaction_ids").map { |id| "insider_#{id}" },
          insiders: row.fetch("insiders"),
          sources: row.fetch("filing_ids").map { |id| FilingProvenance.render(@filings.fetch(id), as_of: @as_of) }
        )
      end
    end
  end
end
