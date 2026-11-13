# frozen_string_literal: true

class ClusterAlertValidity
  # Column expressions are internal callers' SQL, never request parameters.
  def self.sql(snapshot_column:, filing_column:, as_of:, max_filing_id: nil)
    effective = Form4ReadScope.new(as_of:, max_filing_id:).effective_filings.select(:id).to_sql
    now = ApplicationRecord.connection.quote(as_of)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM insider_cluster_snapshots snapshot
        WHERE snapshot.id = #{snapshot_column} AND snapshot.primary_filing_id = #{filing_column}
          AND snapshot.observed_at <= #{now}
          AND snapshot.filing_ids @> ARRAY[#{filing_column}]::bigint[]
          AND NOT EXISTS (
            SELECT 1 FROM unnest(snapshot.filing_ids) sources(id) WHERE sources.id NOT IN (#{effective})
          )
          AND NOT EXISTS (
            SELECT 1 FROM unnest(snapshot.transaction_ids) members(id)
            LEFT JOIN insider_transactions source ON source.id = members.id
            WHERE source.id IS NULL OR NOT (source.filing_id = ANY(snapshot.filing_ids))
              OR source.owner_seq <> 1 OR source.security_table <> 'non_derivative'
              OR source.transaction_code IS DISTINCT FROM snapshot.transaction_code
              OR source.issuer_cik IS DISTINCT FROM snapshot.issuer_cik
          )
      )
    SQL
  end
end
