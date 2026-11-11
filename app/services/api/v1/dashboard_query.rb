# frozen_string_literal: true

module Api
  module V1
    class DashboardQuery
      def initialize(user:, days:, limit:, as_of: Time.current)
        @user, @days, @limit, @as_of = user, days, limit, as_of
        @from_date = @as_of.to_date - (days - 1)
        @date_filters = { "date_from" => @from_date.iso8601, "date_to" => @as_of.to_date.iso8601 }
      end

      def call
        @bounds = ActivityQuery::BOUNDS.transform_values { |model| model.maximum(:id) || 0 }
        follows = @user.follows.current.where("id <= ? AND followed_at <= ?", @bounds.fetch("follows"), @as_of)
        follow_count = follows.count
        clusters = cluster_section
        watchlist = watchlist_section(follow_count:)
        counts, latest = filing_summary
        {
          data: {
            summary: counts.merge(watchlist_items: follow_count, watchlist_activity_events: watchlist.fetch(:meta).fetch(:total_count),
              cluster_windows: clusters.fetch(:meta).fetch(:total_count)),
            upcoming_deadlines: [ deadline ], top_clusters: clusters, watchlist_activity: watchlist,
            top_unusual: unusual_section
          },
          meta: { as_of: @as_of.iso8601(6), window: { days: @days, date_from: @from_date.iso8601,
            date_to: @as_of.to_date.iso8601, timezone: "UTC" }, latest_filed_at: latest,
            available_sources: %w[insider institutional], scoring_available: false,
            market_movers_available: false, disclaimer: FilingsIntel::DISCLAIMER }
        }
      end

      private

      def filing_summary
        form4 = Form4ReadScope.new(as_of: @as_of, max_filing_id: @bounds.fetch("filings"),
          max_transaction_id: @bounds.fetch("transactions"))
        filings = form4.visible_filings.where("filings.filed_at >= ?", @from_date.beginning_of_day)
        reports = InstitutionalReportScope.new(as_of: @as_of, max_report_id: @bounds.fetch("reports"),
          max_filing_id: @bounds.fetch("filings")).visible_reports
          .where("COALESCE(filings.filed_at, institutional_reports.filed_at) >= ?", @from_date.beginning_of_day)
        filing_count, last_form4 = filings.pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(filings.filed_at)"))
        report_count, last_report = reports.except(:select).pick(Arel.sql("COUNT(*)"),
          Arel.sql("MAX(COALESCE(filings.filed_at, institutional_reports.filed_at))"))
        transactions = form4.transactions.where(owner_seq: 1).where("filings.filed_at >= ?", @from_date.beginning_of_day).count
        [ { form4_filings: filing_count, insider_transactions: transactions, institutional_reports: report_count },
          [ last_form4, last_report ].compact.max ]
      end

      def cluster_section
        filters = InsiderClustersParameters.normalize(@date_filters)
        page = page_for(resource: "insider_clusters", filters:, sorts: InsiderClustersQuery::SORTS, sort: "-insider_count")
        result = InsiderClustersQuery.new(page:, filters:).call
        serializer = InsiderClusterSerializer.new(rows: result.records, as_of: @as_of)
        { data: result.records.map { |row| serializer.render(row) }, meta: result.meta.merge(
          window_days: ActivityMethodology.window_days, minimum_insiders: ActivityMethodology.minimum_insiders,
          definition_minimum_insiders: ActivityMethodology.minimum_insiders, filters:) }
      end

      def watchlist_section(follow_count:)
        filters = ActivityParameters.normalize(@date_filters.merge("watchlist_only" => "true"))
        if follow_count.zero?
          return { data: [], meta: { total_count: 0, has_more: false, next_cursor: nil, limit: @limit,
            sort: "-occurred_at", as_of: @as_of.iso8601(6), filters:, available_sources: %w[insider institutional],
            scoring_available: false, sector_available: false } }
        end
        page = page_for(resource: "activity", filters:, sorts: ActivityQuery::SORTS, sort: "-occurred_at", private: true)
        result = ActivityQuery.new(page:, filters:, user: @user).call
        serializer = ActivitySerializer.new(rows: result.records, as_of: @as_of)
        { data: result.records.map { |row| serializer.render(row) }, meta: result.meta.merge(filters:,
          available_sources: %w[insider institutional], scoring_available: false, sector_available: false) }
      end

      def page_for(resource:, filters:, sorts:, sort:, private: false)
        context = { "resource" => resource }
        context["user_id"] = @user.id if private
        CursorPage.new(parameters: filters.merge("sort" => sort, "limit" => @limit.to_s), context:, sorts:,
          default_sort: sort, as_of: @as_of, captured_bounds: @bounds)
      end

      def unusual_section
        limit = PlanCatalog.limit_for(@user, :unusual_activity_results)
        { data: [], meta: { available: false, unavailable_reason: "scoring_not_active", total_count: nil,
          truncated: false, feature: "unusual_activity_results", limit: [ limit || @limit, @limit ].min } }
      end

      def deadline
        value = Form13fDeadline.new(today: @as_of.in_time_zone("America/New_York").to_date).next
        { form_type: "13F-HR", period_of_report: value.period_end, due_date: value.due_date,
          days_remaining: value.days_remaining, timezone: "America/New_York",
          source_url: "https://www.sec.gov/rules-regulations/staff-guidance/frequently-asked-questions-about-form-13f" }
      end
    end
  end
end
