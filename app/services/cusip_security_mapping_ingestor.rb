# frozen_string_literal: true

# Persists OpenFIGI enrichment separately from the as-reported 13F holdings.
# A changed lookup marks prior rows stale instead of rewriting or deleting them.
class CusipSecurityMappingIngestor
  SOURCE = "openfigi"

  def self.call(results, now: Time.current)
    new(results, now:).call
  end

  def initialize(results, now: Time.current)
    @results = results
    @now = now
  end

  def call
    @results.each { |result| persist_result(result) }
    @results.size
  end

  private

  def persist_result(result)
    ApplicationRecord.transaction do
      stale_previous_mappings(result.cusip)

      if result.matches.empty?
        upsert_mapping(result.cusip, nil, 0, "unmapped", result.error)
      else
        status = result.matches.one? ? "mapped" : "ambiguous"
        result.matches.each_with_index do |match, index|
          security = upsert_security(match)
          upsert_mapping(result.cusip, security.id, index + 1, status, nil)
        end
      end
    end
  end

  def stale_previous_mappings(cusip)
    CusipSecurityMapping.where(cusip:, source: SOURCE).update_all(status: "stale", updated_at: @now)
  end

  def upsert_security(match)
    Security.upsert(
      {
        figi: match.figi,
        ticker: match.ticker,
        name: match.name,
        security_type: match.security_type,
        market_sector: match.market_sector,
        exchange_code: match.exchange_code,
        share_class_figi: match.share_class_figi,
        composite_figi: match.composite_figi,
        source: SOURCE,
        created_at: @now,
        updated_at: @now
      },
      unique_by: :index_securities_on_figi
    )
    Security.find_by!(figi: match.figi)
  end

  def upsert_mapping(cusip, security_id, result_seq, status, error)
    existing = CusipSecurityMapping.find_by(cusip:, source: SOURCE, result_seq:)
    CusipSecurityMapping.upsert(
      {
        cusip:, security_id:, source: SOURCE, result_seq:, status:, error:,
        first_seen_at: existing&.first_seen_at || @now,
        last_checked_at: @now,
        created_at: existing&.created_at || @now,
        updated_at: @now
      },
      unique_by: :index_cusip_mappings_on_cusip_source_sequence
    )
  end
end
