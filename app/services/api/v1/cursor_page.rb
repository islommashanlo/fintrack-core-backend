# frozen_string_literal: true

module Api
  module V1
    # Keyset pagination over a relation. SQL expressions come only from each
    # caller's fixed sort map; request values are bound separately.
    class CursorPage
      Result = Data.define(:records, :meta)
      attr_reader :as_of

      def initialize(parameters:, context:, sorts:, default_sort:, bounds: {}, as_of: Time.current)
        @sorts = sorts
        @sort = parameters.fetch("sort", default_sort)
        @field = @sort.delete_prefix("-")
        invalid!("sort") unless @sorts.key?(@field)
        @limit = Integer(parameters.fetch("limit", "50"), 10)
        invalid!("limit") unless @limit.between?(1, 100)
        @context = context.merge("filters" => parameters.except("cursor", "limit", "sort"), "sort" => @sort)
        @snapshot = restore(parameters["cursor"]) || {
          "as_of" => as_of.iso8601(6), "bounds" => bounds.transform_values { |model| model.maximum(:id) || 0 }
        }
        @as_of = Time.iso8601(@snapshot.fetch("as_of"))
      rescue ArgumentError
        invalid!("limit")
      end

      def bound(name)
        @snapshot.fetch("bounds").fetch(name)
      end

      def call(scope, preload: [])
        table = scope.klass.table_name
        column = @sorts.fetch(@field)
        direction = @sort.start_with?("-") ? "DESC" : "ASC"
        count = scope.except(:select, :order).count
        records = after_cursor(scope, column, table)
          .except(:select).select("#{table}.*", "#{column} AS api_sort_value")
          .reorder(Arel.sql("#{column} #{direction} NULLS LAST, #{table}.id #{direction}"))
          .limit(@limit + 1).preload(preload).to_a
        has_more = records.size > @limit
        records = records.first(@limit)
        Result.new(records:, meta: {
          total_count: count, has_more:, next_cursor: has_more ? encode(records.last) : nil,
          limit: @limit, sort: @sort, as_of: @snapshot.fetch("as_of")
        })
      end

      private

      def restore(cursor)
        return unless cursor

        invalid!("cursor") if cursor.bytesize > 8192
        payload = verifier.verified(cursor, purpose: "pagination")
        invalid!("cursor") unless payload.is_a?(Hash) && payload["version"] == 1 && payload["context"] == @context
        payload.fetch("snapshot")
      end

      def after_cursor(scope, column, table)
        return scope unless @snapshot.key?("last_id")

        operator = @sort.start_with?("-") ? "<" : ">"
        if @snapshot["last_value"].nil?
          scope.where("(#{column}) IS NULL AND #{table}.id #{operator} ?", @snapshot.fetch("last_id"))
        else
          scope.where(<<~SQL, value: @snapshot.fetch("last_value"), id: @snapshot.fetch("last_id"))
            ((#{column}) #{operator} :value OR
              ((#{column}) = :value AND #{table}.id #{operator} :id) OR (#{column}) IS NULL)
          SQL
        end
      end

      def encode(record)
        value = record["api_sort_value"]
        value = case value
        when Time, DateTime then value.iso8601(6)
        when Date then value.iso8601
        when BigDecimal then value.to_s("F")
        else value
        end
        snapshot = @snapshot.merge("last_id" => record.id, "last_value" => value)
        verifier.generate({ "version" => 1, "context" => @context, "snapshot" => snapshot },
                          purpose: "pagination", expires_in: 24.hours)
      end

      def verifier
        Rails.application.message_verifier("api.v1.read_pages")
      end

      def invalid!(parameter)
        raise InvalidParameter, "Invalid #{parameter} parameter"
      end
    end
  end
end
