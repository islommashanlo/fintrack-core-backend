# frozen_string_literal: true

module News
  module Visibility
    module_function

    def items(as_of:)
      NewsItem.publishable.where(provider: Publication.providers)
        .where("news_items.observed_at <= ? AND news_items.published_at <= ?", as_of, as_of)
        .where("(news_items.source || ' ' || news_items.title) !~* ? AND news_items.source !~ '[<>[:cntrl:]]' AND news_items.title !~ '[<>[:cntrl:]]'", Publication.language_pattern)
        .where("news_items.url ~ ?", '^https://[^/?#@[:space:][:cntrl:]]+([/?#][^[:space:][:cntrl:]]*)?$')
    end

    def mentions(as_of:)
      NewsMention.joins(<<~SQL).where("news_mentions.observed_at <= ?", as_of)
        LEFT JOIN filers news_filer ON news_mentions.entity_type = 'Filer' AND news_filer.id = news_mentions.entity_id
        LEFT JOIN institutional_filers news_fund ON news_mentions.entity_type = 'InstitutionalFiler' AND news_fund.id = news_mentions.entity_id
      SQL
        .where(<<~SQL)
          (news_mentions.role = 'fund' AND news_fund.id IS NOT NULL) OR
          (news_mentions.role = 'issuer' AND news_filer.filer_type = 'issuer') OR
          (news_mentions.role = 'person' AND news_filer.filer_type = 'insider')
        SQL
    end

    # Caller-owned aliases and row ceilings only; request values never enter SQL.
    def follow_match(as_of:, max_filing_id: nil)
      ApplicationRecord.sanitize_sql_array([ <<~SQL, as_of: ])
        (follows.target_type = 'Insider' AND news_mentions.role = 'person' AND follows.target_key = news_filer.cik) OR
        (follows.target_type = 'InstitutionalFiler' AND news_mentions.role = 'fund' AND follows.target_key = news_fund.cik) OR
        (follows.target_type = 'Ticker' AND news_mentions.role = 'issuer' AND news_filer.cik = (
          SELECT issuer_cik FROM filings WHERE UPPER(issuer_ticker) = follows.target_key
            AND form_type IN ('4', '4/A') AND parse_status = 'parsed'
            #{max_filing_id ? "AND id <= #{Integer(max_filing_id)}" : ''}
            AND filed_at <= :as_of AND ingested_at <= :as_of AND (parsed_at IS NULL OR parsed_at <= :as_of)
          ORDER BY filed_at DESC, accession_no DESC LIMIT 1
        ))
      SQL
    end
  end
end
