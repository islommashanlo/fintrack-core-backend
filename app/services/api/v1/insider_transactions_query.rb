# frozen_string_literal: true

module Api
  module V1
    class InsiderTransactionsQuery
      VALUE_SQL = <<~SQL.squish.freeze
        CASE WHEN insider_transactions.price IS NOT NULL AND NOT insider_transactions.price_suspect
          THEN insider_transactions.shares * insider_transactions.price END
      SQL
      SORT_COLUMNS = {
        "filed_at" => "filings.filed_at",
        "transaction_date" => "insider_transactions.transaction_date",
        "value" => VALUE_SQL
      }.freeze
      ROLE_COLUMNS = {
        "director" => :is_director, "officer" => :is_officer,
        "ten_percent_owner" => :is_ten_percent_owner, "other" => :is_other
      }.freeze
      FILTERS = %w[type code role direction insider_cik issuer_cik ticker security_table
                   min_value max_value date_from date_to].freeze
      PARAMETERS = (FILTERS + %w[sort limit cursor]).freeze
      Result = Data.define(:records, :meta)

      def initialize(parameters:, as_of: Time.current, maximum_limit: 100, cursor_context: nil)
        @parameters = parameters.stringify_keys
        @cursor_context = cursor_context
        validate_parameters!
        @filters = normalized_filters
        @sort = @parameters.fetch("sort", "-filed_at")
        @sort_field = @sort.delete_prefix("-")
        invalid!("sort") unless SORT_COLUMNS.key?(@sort_field)
        @limit = Integer(@parameters.fetch("limit", "50"), 10)
        invalid!("limit") unless @limit.between?(1, maximum_limit)
        @snapshot = snapshot(as_of)
      rescue ArgumentError
        invalid!("limit")
      end

      def call
        scope = filtered_scope
        total_count = scope.count
        records = after_cursor(scope).reorder(Arel.sql(order_sql)).limit(@limit + 1).preload(:filing).to_a
        has_more = records.length > @limit
        records = records.first(@limit)

        Result.new(records:, meta: {
          total_count:, has_more:, next_cursor: has_more ? next_cursor(records.last) : nil,
          limit: @limit, sort: @sort, as_of: @snapshot.fetch("as_of")
        })
      end

      def relation
        filtered_scope
      end

      private

      def validate_parameters!
        unknown = @parameters.keys - PARAMETERS
        invalid!(unknown.first) if unknown.any?
        @parameters.each { |key, value| invalid!(key) unless value.is_a?(String) && value.present? }
      end

      def normalized_filters
        filters = @parameters.slice(*FILTERS)
        filters["type"] ||= "all"
        enum!(filters, "type", %w[all open_market administrative])
        enum!(filters, "role", ROLE_COLUMNS.keys)
        enum!(filters, "direction", %w[purchase sale other])
        enum!(filters, "security_table", InsiderTransaction::SECURITY_TABLES)
        %w[insider_cik issuer_cik].each do |key|
          invalid!(key) if filters[key] && !filters[key].match?(/\A\d{10}\z/)
        end
        if filters["ticker"]
          filters["ticker"] = filters["ticker"].upcase
          invalid!("ticker") unless filters["ticker"].match?(/\A[A-Z0-9][A-Z0-9.-]{0,19}\z/)
        end
        if filters["code"]
          codes = filters["code"].upcase.split(",", -1)
          invalid!("code") unless codes.all? { |code| code.match?(/\A[A-Z]\z/) }
          filters["code"] = codes.uniq.sort.join(",")
        end
        normalize_ranges!(filters)
        filters
      end

      def normalize_ranges!(filters)
        %w[date_from date_to].each do |key|
          next unless filters[key]

          invalid!(key) unless filters[key].match?(/\A\d{4}-\d{2}-\d{2}\z/)
          begin
            filters[key] = Date.iso8601(filters[key]).iso8601
          rescue Date::Error
            invalid!(key)
          end
        end
        %w[min_value max_value].each do |key|
          next unless filters[key]

          invalid!(key) unless filters[key].match?(/\A\d+(?:\.\d+)?\z/)
          filters[key] = BigDecimal(filters[key]).to_s("F")
        end
        invalid!("date_to") if filters.values_at("date_from", "date_to").all? && filters["date_from"] > filters["date_to"]
        if filters.values_at("min_value", "max_value").all? && BigDecimal(filters["min_value"]) > BigDecimal(filters["max_value"])
          invalid!("max_value")
        end
      end

      def enum!(filters, key, values)
        invalid!(key) if filters[key] && !values.include?(filters[key])
      end

      def snapshot(as_of)
        return {
          "as_of" => as_of.iso8601(6), "max_id" => InsiderTransaction.maximum(:id) || 0,
          "max_filing_id" => Filing.maximum(:id) || 0
        } unless @parameters["cursor"]

        invalid!("cursor") if @parameters["cursor"].bytesize > 8192
        payload = verifier.verified(@parameters["cursor"], purpose: "pagination")
        unless payload.is_a?(Hash) && payload["version"] == 1 && payload["filters"] == @filters && payload["sort"] == @sort &&
            payload["context"] == @cursor_context
          invalid!("cursor")
        end
        payload
      end

      def filtered_scope
        scope = Form4ReadScope.new(as_of: @snapshot.fetch("as_of"), max_filing_id: @snapshot.fetch("max_filing_id"),
                                   max_transaction_id: @snapshot.fetch("max_id")).transactions
        case @filters["type"]
        when "open_market" then scope = scope.where(transaction_code: InsiderTransaction::OPEN_MARKET_CODES)
        when "administrative" then scope = excluding_codes(scope, InsiderTransaction::OPEN_MARKET_CODES)
        end
        scope = scope.where(transaction_code: @filters["code"].split(",")) if @filters["code"]
        case @filters["direction"]
        when "purchase" then scope = scope.where(transaction_code: "P")
        when "sale" then scope = scope.where(transaction_code: "S")
        when "other" then scope = excluding_codes(scope, InsiderTransaction::OPEN_MARKET_CODES)
        end
        scope = scope.where(ROLE_COLUMNS.fetch(@filters["role"]) => true) if @filters["role"]
        %w[insider_cik issuer_cik security_table].each { |key| scope = scope.where(key => @filters[key]) if @filters[key] }
        scope = scope.where("UPPER(insider_transactions.issuer_ticker) = ?", @filters["ticker"]) if @filters["ticker"]
        scope = scope.where("#{VALUE_SQL} >= ?", @filters["min_value"]) if @filters["min_value"]
        scope = scope.where("#{VALUE_SQL} <= ?", @filters["max_value"]) if @filters["max_value"]
        scope = scope.where("insider_transactions.transaction_date >= ?", @filters["date_from"]) if @filters["date_from"]
        scope = scope.where("insider_transactions.transaction_date <= ?", @filters["date_to"]) if @filters["date_to"]
        scope
      end

      def excluding_codes(scope, codes)
        scope.where("insider_transactions.transaction_code NOT IN (?) OR insider_transactions.transaction_code IS NULL", codes)
      end

      def after_cursor(scope)
        return scope unless @snapshot.key?("last_id")

        column = SORT_COLUMNS.fetch(@sort_field)
        operator = @sort.start_with?("-") ? "<" : ">"
        if @snapshot["last_value"].nil?
          scope.where("(#{column}) IS NULL AND insider_transactions.id #{operator} ?", @snapshot.fetch("last_id"))
        else
          scope.where(<<~SQL, value: @snapshot.fetch("last_value"), id: @snapshot.fetch("last_id"))
            ((#{column}) #{operator} :value OR
              ((#{column}) = :value AND insider_transactions.id #{operator} :id) OR (#{column}) IS NULL)
          SQL
        end
      end

      def order_sql
        direction = @sort.start_with?("-") ? "DESC" : "ASC"
        "#{SORT_COLUMNS.fetch(@sort_field)} #{direction} NULLS LAST, insider_transactions.id #{direction}"
      end

      def next_cursor(record)
        value = case @sort_field
        when "filed_at" then record.filing.filed_at.iso8601(6)
        when "transaction_date" then record.transaction_date&.iso8601
        when "value" then record.reported_value&.to_s("F")
        end
        payload = @snapshot.merge("version" => 1, "filters" => @filters, "sort" => @sort,
                                  "last_id" => record.id, "last_value" => value)
        payload["context"] = @cursor_context if @cursor_context
        verifier.generate(payload, purpose: "pagination", expires_in: 24.hours)
      end

      def verifier
        Rails.application.message_verifier("api.v1.insider_transactions")
      end

      def invalid!(parameter)
        raise InvalidParameter, "Invalid #{parameter} parameter"
      end
    end
  end
end
