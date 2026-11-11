# frozen_string_literal: true

module Api
  module V1
    # Candidate filters use indexed stored names. Resolve canonical profiles before
    # matching again, so an old name cannot masquerade as a current match.
    class SearchSources
      BOUNDS = { "filings" => Filing, "transactions" => InsiderTransaction, "funds" => InstitutionalFiler,
        "filers" => Filer, "securities" => Security, "mappings" => CusipSecurityMapping, "reports" => InstitutionalReport }.freeze

      def initialize(page:, query:)
        @page, @query = page, query
      end

      def sql(group)
        # Leave parameters unbound until SearchQuery adds ranking to this template.
        source = case group
        when "companies" then companies
        when "funds" then funds
        when "insiders" then insiders
        else raise ArgumentError, "Unknown search group"
        end
        source
      end

      def matching(name:, ticker: nil, cik: nil)
        conditions = [ "LOWER(#{name}) LIKE :contains" ]
        conditions << "LOWER(#{ticker}) LIKE :contains" if ticker
        conditions << "#{cik} = :cik" if cik && @query.match?(/\A\d{1,10}\z/)
        conditions << "LOWER(#{name}) % :query" if @query.length >= 3 && @query.match?(/[[:alnum:]]/)
        "(#{conditions.join(' OR ')})"
      end

      def binds
        literal = ApplicationRecord.sanitize_sql_like(@query.downcase)
        { query: @query.downcase, contains: "%#{literal}%", prefix: "#{literal}%",
          cik: @query.match?(/\A\d{1,10}\z/) ? @query.rjust(10, "0") : nil,
          as_of: @page.as_of }
      end

      private

      def visible_filings
        Form4ReadScope.new(as_of: @page.as_of, max_filing_id: @page.bound("filings")).visible_filings.to_sql
      end

      def mapped_security(table = "s")
        <<~SQL.squish
          #{table}.id <= #{@page.bound('securities')} AND EXISTS (
            SELECT 1 FROM cusip_security_mappings m WHERE m.security_id = #{table}.id AND m.status = 'mapped'
              AND m.id <= #{@page.bound('mappings')} AND m.first_seen_at <= :as_of)
        SQL
      end

      def companies
        <<~SQL
          WITH candidate_keys AS (
            SELECT UPPER(f.issuer_ticker) AS ticker FROM filings f
            WHERE f.id <= #{@page.bound('filings')} AND f.parse_status = 'parsed' AND f.form_type IN ('4', '4/A')
              AND f.filed_at <= :as_of AND #{matching(name: 'f.issuer_name', ticker: 'f.issuer_ticker', cik: 'f.issuer_cik')}
            UNION
            SELECT UPPER(s.ticker) FROM securities s WHERE #{mapped_security}
              AND #{matching(name: 's.name', ticker: 's.ticker')}
          )
          SELECT 'issuer'::text AS entity_type, k.ticker AS entity_key, k.ticker,
            f.issuer_cik AS cik, COALESCE(f.issuer_name, CASE WHEN f.id IS NULL THEN s.name END) AS name,
            f.id AS primary_filing_id
          FROM candidate_keys k
          LEFT JOIN LATERAL (
            SELECT id, issuer_cik, issuer_name FROM filings
            WHERE UPPER(issuer_ticker) = k.ticker AND parse_status = 'parsed' AND form_type IN ('4', '4/A')
              AND filed_at <= :as_of AND id <= #{@page.bound('filings')}
            ORDER BY filed_at DESC, accession_no DESC LIMIT 1
          ) f ON TRUE
          LEFT JOIN LATERAL (
            SELECT s.name FROM securities s WHERE f.id IS NULL AND UPPER(s.ticker) = k.ticker AND #{mapped_security}
            ORDER BY s.id DESC LIMIT 1
          ) s ON TRUE
          WHERE k.ticker ~ '^[A-Z0-9][A-Z0-9.-]{0,19}$'
        SQL
      end

      def funds
        reports = InstitutionalReportScope.new(as_of: @page.as_of, max_report_id: @page.bound("reports"),
          max_filing_id: @page.bound("filings")).visible_reports.to_sql
        <<~SQL
          SELECT 'fund'::text AS entity_type, i.cik AS entity_key, NULL::text AS ticker,
            i.cik, i.name, r.filing_id AS primary_filing_id
          FROM institutional_filers i
          LEFT JOIN LATERAL (
            SELECT filing_id FROM (#{reports}) visible WHERE institutional_filer_id = i.id
            ORDER BY known_filed_at DESC, known_accession DESC LIMIT 1
          ) r ON TRUE
          WHERE i.id <= #{@page.bound('funds')} AND i.cik ~ '^[0-9]{10}$'
            AND #{matching(name: 'i.name', cik: 'i.cik')}
        SQL
      end

      def insiders
        <<~SQL
          WITH visible AS (#{visible_filings}), candidate_keys AS (
            SELECT t.insider_cik AS cik FROM insider_transactions t INNER JOIN visible f ON f.id = t.filing_id
            WHERE t.id <= #{@page.bound('transactions')} AND #{matching(name: 't.insider_name', cik: 't.insider_cik')}
            UNION
            SELECT p.cik FROM filers p WHERE p.id <= #{@page.bound('filers')} AND #{matching(name: 'p.name', cik: 'p.cik')}
              AND EXISTS (SELECT 1 FROM visible f WHERE f.owner_ciks @> ARRAY[p.cik]::varchar[] OR EXISTS (
                SELECT 1 FROM insider_transactions tx WHERE tx.filing_id = f.id AND tx.insider_cik = p.cik
                  AND tx.id <= #{@page.bound('transactions')}))
          )
          SELECT 'person'::text AS entity_type, k.cik AS entity_key, NULL::text AS ticker, k.cik,
            COALESCE(NULLIF(BTRIM(t.insider_name), ''), p.name) AS name, latest.id AS primary_filing_id
          FROM candidate_keys k
          LEFT JOIN filers p ON p.cik = k.cik AND p.id <= #{@page.bound('filers')}
          LEFT JOIN LATERAL (
            SELECT tx.insider_name FROM insider_transactions tx INNER JOIN visible f ON f.id = tx.filing_id
            WHERE tx.insider_cik = k.cik AND tx.id <= #{@page.bound('transactions')}
            ORDER BY f.filed_at DESC, f.accession_no DESC, tx.id DESC LIMIT 1
          ) t ON TRUE
          INNER JOIN LATERAL (
            SELECT f.id FROM visible f WHERE f.owner_ciks @> ARRAY[k.cik]::varchar[] OR EXISTS (
              SELECT 1 FROM insider_transactions tx WHERE tx.filing_id = f.id AND tx.insider_cik = k.cik
                AND tx.id <= #{@page.bound('transactions')})
            ORDER BY f.filed_at DESC, f.accession_no DESC LIMIT 1
          ) latest ON TRUE
          WHERE k.cik ~ '^[0-9]{10}$'
        SQL
      end
    end
  end
end
