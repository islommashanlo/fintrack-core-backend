# frozen_string_literal: true

module Api
  module V1
    class ActivityQuery
      BOUNDS = {
        "filings" => Filing, "transactions" => InsiderTransaction, "reports" => InstitutionalReport,
        "holdings" => InstitutionalHolding, "mappings" => CusipSecurityMapping, "securities" => Security, "follows" => Follow
      }.freeze
      SORTS = { "occurred_at" => "activity.occurred_at", "value" => "activity.value", "score" => "activity.score" }.freeze
      POSITION_FIELDS = %w[period_of_report prior_period_of_report cusip put_call share_type change_type
                           name_of_issuer title_of_class shares_before shares_after shares_delta
                           value_usd_before value_usd_after value_usd_delta current_suspect prior_suspect].freeze
      DECIMAL_FIELDS = %w[shares_before shares_after shares_delta value_usd_before value_usd_after value_usd_delta].freeze

      def initialize(page:, filters: {}, user: nil)
        @page = page
        @filters = filters
        @user = user
      end

      def call
        @page.call_sql(filtered_sql)
      end

      def find(identifier)
        if identifier.fetch("source") == "insider"
          sql = "SELECT activity.* FROM (#{insider_sql(history: true)}) activity WHERE source_id = ?"
          binds = [ identifier.fetch("id") ]
        else
          source = institutional_sql(report_ids: identifier.fetch("reports"), fund_id: identifier.fetch("fund_id"),
                                     period: identifier.fetch("period"))
          sql = "SELECT activity.* FROM (#{source}) activity WHERE event_key = ?"
          binds = [ identifier.fetch("key") ]
        end
        row = CursorPage.sql_rows(ApplicationRecord.sanitize_sql([ sql, *binds ])).first
        row || raise(ActiveRecord::RecordNotFound)
      end

      private

      def filtered_sql
        conditions = [ "TRUE" ]
        binds = {}
        %w[source direction level sector].each do |key|
          next unless @filters[key]

          conditions << "activity.#{key} = :#{key}"
          binds[key.to_sym] = @filters[key]
        end
        if @filters["type"] && @filters["type"] != "all"
          conditions << "activity.activity_type = :type"
          binds[:type] = @filters["type"]
        end
        %w[min_value min_score].each do |key|
          next unless @filters[key]

          conditions << "activity.#{key == 'min_value' ? 'value' : 'score'} >= :#{key}"
          binds[key.to_sym] = @filters[key]
        end
        if @filters["date_from"]
          conditions << "activity.occurred_at >= :date_from"
          binds[:date_from] = Date.iso8601(@filters["date_from"]).beginning_of_day
        end
        if @filters["date_to"]
          conditions << "activity.occurred_at < :date_to"
          binds[:date_to] = Date.iso8601(@filters["date_to"]).next_day.beginning_of_day
        end
        conditions << watchlist_sql if @filters["watchlist_only"] == "true"
        ApplicationRecord.sanitize_sql([ <<~SQL, binds ])
          SELECT activity.* FROM (#{insider_sql} UNION ALL #{institutional_sql}) activity
          WHERE #{conditions.join(' AND ')}
        SQL
      end

      def insider_sql(history: false)
        scope = Form4ReadScope.new(as_of: @page.as_of, max_filing_id: @page.bound("filings"),
                                   max_transaction_id: @page.bound("transactions"))
          .transactions(effective: !history).where(owner_seq: 1).select("insider_transactions.*")
        <<~SQL
          SELECT 'insider:' || t.id::text AS event_key, 'insider'::text AS source, t.id AS source_id,
                 f.id AS primary_filing_id, f.filed_at AS occurred_at,
                 CASE WHEN t.price IS NOT NULL AND NOT t.price_suspect THEN t.shares * t.price END AS value,
                 CASE t.transaction_code WHEN 'P' THEN 'purchase' WHEN 'S' THEN 'sale' ELSE 'other' END AS direction,
                 CASE WHEN t.transaction_code IN ('P', 'S') THEN 'open_market' ELSE 'administrative' END AS activity_type,
                 NULL::integer AS score, NULL::text AS level, NULL::text AS sector,
                 UPPER(COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker)) AS ticker,
                 NULL::bigint AS fund_id, NULL::text AS fund_cik, f.period_of_report,
                 NULL::text AS cusip, NULL::text AS put_call, NULL::text AS share_type,
                 ARRAY[]::bigint[] AS current_report_ids, ARRAY[]::bigint[] AS prior_report_ids,
                 ARRAY[]::bigint[] AS context_report_ids,
                 ARRAY(SELECT owners.id FROM insider_transactions owners
                   WHERE owners.filing_id = t.filing_id AND owners.security_table = t.security_table AND owners.txn_seq = t.txn_seq
                     AND owners.id <= #{@page.bound('transactions')}
                   ORDER BY owners.owner_seq, owners.id) AS reporting_owner_ids,
                 NULL::jsonb AS position_data
          FROM (#{scope.to_sql}) t INNER JOIN filings f ON f.id = t.filing_id
        SQL
      end

      def institutional_sql(report_ids: nil, fund_id: nil, period: nil)
        reports = InstitutionalReportScope.new(as_of: @page.as_of, max_report_id: @page.bound("reports"),
                                               max_filing_id: @page.bound("filings"), report_ids:)
        diffs = InstitutionalPositionDiffQuery.new(institutional_filer_id: fund_id, period_of_report: period,
          report_scope: reports, max_holding_id: @page.bound("holdings"), include_context: true).to_sql
        position = POSITION_FIELDS.map { |key| "'#{key}', d.#{key}#{DECIMAL_FIELDS.include?(key) ? '::text' : ''}" }.join(", ")
        <<~SQL
          SELECT 'institutional:' || jsonb_build_array(i.cik, d.period_of_report, d.cusip, d.put_call, d.share_type,
                   d.current_context_ids, d.prior_context_ids)::text AS event_key,
                 'institutional'::text AS source, NULL::bigint AS source_id,
                 latest.filing_id AS primary_filing_id, latest.known_at AS occurred_at,
                 CASE WHEN NOT d.current_suspect AND NOT d.prior_suspect THEN ABS(d.value_usd_delta) END AS value,
                 CASE WHEN d.change_type IN ('new', 'add') THEN 'increase' ELSE 'decrease' END AS direction,
                 'position_change'::text AS activity_type,
                 NULL::integer AS score, NULL::text AS level, NULL::text AS sector, mapping.ticker,
                 i.id AS fund_id, i.cik AS fund_cik, d.period_of_report, d.cusip, d.put_call, d.share_type,
                 d.current_report_ids, COALESCE(d.prior_report_ids, ARRAY[]::bigint[]) AS prior_report_ids,
                 d.current_context_ids || d.prior_context_ids AS context_report_ids,
                 ARRAY[]::bigint[] AS reporting_owner_ids, jsonb_build_object(#{position}) AS position_data
          FROM (#{diffs}) d INNER JOIN institutional_filers i ON i.id = d.institutional_filer_id
          INNER JOIN LATERAL (
            SELECT r.filing_id, COALESCE(f.filed_at, r.filed_at) AS known_at
            FROM institutional_reports r INNER JOIN filings f ON f.id = r.filing_id
            WHERE r.id = ANY(d.current_context_ids || d.prior_context_ids)
            ORDER BY COALESCE(f.filed_at, r.filed_at) DESC, f.accession_no DESC LIMIT 1
          ) latest ON TRUE
          LEFT JOIN LATERAL (
            SELECT CASE WHEN COUNT(DISTINCT UPPER(s.ticker)) = 1 THEN MIN(UPPER(s.ticker)) END AS ticker
            FROM cusip_security_mappings m INNER JOIN securities s ON s.id = m.security_id
            WHERE m.cusip = d.cusip AND m.status = 'mapped' AND m.id <= #{@page.bound('mappings')}
              AND s.id <= #{@page.bound('securities')}
              AND m.first_seen_at <= #{ApplicationRecord.connection.quote(@page.as_of)}
          ) mapping ON TRUE
          WHERE d.prior_period_of_report = date_trunc('quarter', d.period_of_report)::date - 1
        SQL
      end

      def watchlist_sql
        ApplicationRecord.sanitize_sql([ <<~SQL, user_id: @user.id, max_follow: @page.bound("follows"), snapshot: @page.as_of ])
          EXISTS (SELECT 1 FROM follows
            WHERE follows.user_id = :user_id AND follows.removed_at IS NULL AND follows.followed_at <= :snapshot AND follows.id <= :max_follow AND (
              (follows.target_type = 'Ticker' AND follows.target_key = activity.ticker)
              OR (follows.target_type = 'InstitutionalFiler' AND follows.target_key = activity.fund_cik)
              OR (follows.target_type = 'Insider' AND EXISTS (
                SELECT 1 FROM insider_transactions owners
                WHERE owners.id = ANY(activity.reporting_owner_ids) AND owners.insider_cik = follows.target_key
              ))
            ))
        SQL
      end
    end
  end
end
