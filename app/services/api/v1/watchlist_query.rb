# frozen_string_literal: true

module Api
  module V1
    class WatchlistQuery
      SORTS = { "created_at" => "follows.followed_at", "entity_key" => "follows.target_key" }.freeze

      def self.call(user:, page:, entity_type: nil)
        if entity_type && !WatchlistTarget::TYPES.key?(entity_type)
          raise InvalidParameter, "Invalid entity_type parameter"
        end
        follows = user.follows.current.where("id <= ? AND followed_at <= ?", page.bound("follows"), page.as_of)
        follows = follows.where(target_type: WatchlistTarget::TYPES.fetch(entity_type)) if entity_type
        sql = ApplicationRecord.sanitize_sql([ <<~SQL, as_of: page.as_of ])
          SELECT follows.*, COALESCE(CASE follows.target_type
            WHEN 'InstitutionalFiler' THEN (SELECT name FROM institutional_filers WHERE cik = follows.target_key)
            WHEN 'Insider' THEN COALESCE((
              SELECT t.insider_name FROM insider_transactions t INNER JOIN filings f ON f.id = t.filing_id
              WHERE t.insider_cik = follows.target_key AND f.parse_status = 'parsed'
                AND f.form_type IN ('4', '4/A') AND f.filed_at <= :as_of
              ORDER BY f.filed_at DESC, f.accession_no DESC, t.id DESC LIMIT 1
            ), (SELECT name FROM filers WHERE cik = follows.target_key))
            WHEN 'Ticker' THEN COALESCE((
              SELECT issuer_name FROM filings
              WHERE UPPER(issuer_ticker) = follows.target_key AND parse_status = 'parsed'
                AND form_type IN ('4', '4/A') AND filed_at <= :as_of
              ORDER BY filed_at DESC, accession_no DESC LIMIT 1
            ), (
              SELECT s.name FROM securities s INNER JOIN cusip_security_mappings m ON m.security_id = s.id
              WHERE UPPER(s.ticker) = follows.target_key AND m.status = 'mapped' AND m.first_seen_at <= :as_of
              ORDER BY m.last_checked_at DESC, m.id DESC LIMIT 1
            )) END, follows.target_key) AS entity_name
          FROM (#{follows.to_sql}) follows
        SQL
        page.call(Follow.from("(#{sql}) follows"))
      end
    end
  end
end
