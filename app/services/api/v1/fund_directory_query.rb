# frozen_string_literal: true

module Api
  module V1
    class FundDirectoryQuery
      PARAMETERS = %w[q period report_type coverage min_portfolio_value_usd max_portfolio_value_usd min_position_count max_position_count min_reported_allocation_turnover_percent max_reported_allocation_turnover_percent sort limit cursor].freeze
      SORTS = { "name" => "LOWER(institutional_filers.name)", "cik" => "institutional_filers.cik",
        "portfolio_value_usd" => "institutional_filers.portfolio_value_usd", "position_count" => "institutional_filers.position_count",
        "reported_allocation_turnover_percent" => "institutional_filers.reported_allocation_turnover_percent" }.freeze
      RANGES = { "portfolio_value_usd" => /\A[0-9]{1,30}(?:\.[0-9]{1,12})?\z/, "position_count" => /\A[0-9]{1,12}\z/,
        "reported_allocation_turnover_percent" => /\A[0-9]{1,3}(?:\.[0-9]{1,12})?\z/ }.freeze
      REPORT_TYPES = { "holdings" => "13F HOLDINGS REPORT", "combination" => "13F COMBINATION REPORT", "notice" => "13F NOTICE" }.freeze
      COVERAGES = %w[complete incomplete_report_set no_effective_holdings no_report history_restricted].freeze
      attr_reader :page

      def initialize(parameters:, history:, as_of:)
        @parameters, @history = parameters, history
        validate_ranges!
        if parameters["report_type"] && !REPORT_TYPES.key?(parameters["report_type"])
          raise InvalidParameter, "Invalid report_type parameter"
        end
        if parameters["coverage"] && !COVERAGES.include?(parameters["coverage"])
          raise InvalidParameter, "Invalid coverage parameter"
        end
        @page = CursorPage.new(parameters:, context: history.context.merge("resource" => "funds", "version" => 2),
          sorts: SORTS, default_sort: "name", bounds: InstitutionalHoldingsQuery::BOUNDS.merge("funds" => InstitutionalFiler), as_of:)
      end

      def call
        period = @parameters["period"] && Date.iso8601(@parameters["period"])
        @history.check!(period, as_of: @page.as_of)
        sql = FundDirectorySql.new(page: @page, history: @history, period:, include_turnover: true).to_sql
        scope = InstitutionalFiler.from("(#{sql}) institutional_filers")
        if @parameters["q"]
          scope = scope.where("name ILIKE ? OR cik = ?", "%#{ApplicationRecord.sanitize_sql_like(@parameters['q'])}%", @parameters["q"])
        end
        if @parameters["coverage"]
          reason = @parameters["coverage"] == "complete" ? nil : @parameters["coverage"]
          scope = scope.where(portfolio_unavailable_reason: reason)
        end
        if @parameters["report_type"]
          scope = scope.where("? = ANY(portfolio_report_types)", REPORT_TYPES.fetch(@parameters["report_type"]))
        end
        RANGES.each_key do |column|
          scope = scope.where("#{column} >= ?", @parameters["min_#{column}"]) if @parameters["min_#{column}"]
          scope = scope.where("#{column} <= ?", @parameters["max_#{column}"]) if @parameters["max_#{column}"]
        end
        result = @history.decorate(@page.call(scope))
        turnover_context = FundTurnoverSerializer.context
        CursorPage::Result.new(records: result.records, meta: result.meta.merge(portfolio_period: period&.iso8601 || "latest_per_fund",
          portfolio_history_limited: !@history.earliest(as_of: @page.as_of).nil?, value_is_aum: false, disclaimer: FilingsIntel::DISCLAIMER,
          turnover_baseline_policy: turnover_context.fetch(:baseline_policy),
          turnover_methodology_version: turnover_context.fetch(:methodology_version)))
      end

      def self.sources(records)
        ids = records.flat_map do |record|
          turnover = record["turnover_record"]
          record["source_report_ids"] + (turnover ? turnover.fetch("current_source_ids") + turnover.fetch("prior_source_ids") : [])
        end
        InstitutionalReport.where(id: ids).includes(:filing).index_by(&:id)
      end

      private

      def validate_ranges!
        RANGES.each do |column, pattern|
          %w[min max].each do |bound|
            key = "#{bound}_#{column}"
            next unless @parameters[key]
            raise InvalidParameter, "Invalid #{key} parameter" unless @parameters[key].match?(pattern)
            if column == "reported_allocation_turnover_percent" && BigDecimal(@parameters[key]) > 100
              raise InvalidParameter, "Invalid #{key} parameter"
            end
          end
          min, max = @parameters.values_at("min_#{column}", "max_#{column}")
          raise InvalidParameter, "Invalid #{column} range" if min && max && BigDecimal(min) > BigDecimal(max)
        end
      end
    end
  end
end
