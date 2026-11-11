# frozen_string_literal: true

module Api
  module V1
    class SearchQuery
      GROUPS = %w[companies funds insiders].freeze
      SORTS = { "relevance" => "activity.relevance" }.freeze

      def initialize(parameters:, as_of: Time.current)
        @parameters, @as_of = parameters, as_of
      end

      def call
        data, metadata = {}, {}
        bounds = SearchSources::BOUNDS.transform_values { |model| model.maximum(:id) || 0 }
        groups = @parameters.fetch("type", "all") == "all" ? GROUPS : [ @parameters.fetch("type") ]
        ApplicationRecord.transaction(requires_new: true) do
          # Fixed per-transaction threshold; pooled connection defaults do not change matching.
          connection = ApplicationRecord.connection
          previous = connection.select_value("SELECT current_setting('pg_trgm.similarity_threshold', true)")
          connection.execute("SET LOCAL pg_trgm.similarity_threshold = 0.3")
          groups.each do |group|
            values = @parameters.merge("type" => group, "sort" => "relevance")
            page = CursorPage.new(parameters: values, context: { "resource" => "search", "group" => group },
              sorts: SORTS, default_sort: "relevance", as_of: @as_of, captured_bounds: bounds)
            source = SearchSources.new(page:, query: @parameters.fetch("q"))
            result = page.call_sql(ranked_sql(source, group))
            serializer = SearchResultSerializer.new(rows: result.records, as_of: page.as_of)
            data[group] = result.records.map { |row| serializer.render(row) }
            metadata[group] = result.meta
          end
          # Also restore the setting when called inside an existing transaction.
          connection.execute(ApplicationRecord.sanitize_sql([
            "SELECT set_config('pg_trgm.similarity_threshold', ?, true)", previous.presence || "0.3"
          ]))
        end
        { data:, meta: { q: @parameters.fetch("q"), groups: metadata, disclaimer: FilingsIntel::DISCLAIMER } }
      end

      private

      def ranked_sql(source, group)
        ApplicationRecord.sanitize_sql([ <<~SQL, source.binds ])
          SELECT matches.*,
            (match_rank * 2 + 1 - name_similarity)::numeric(12,6) AS relevance,
            LOWER(COALESCE(name, '')) || ':' || entity_key AS event_key
          FROM (
            SELECT entities.*,
              CASE WHEN LOWER(ticker) = :query THEN 0 WHEN cik = :cik THEN 1
                WHEN LOWER(name) = :query THEN 2
                WHEN LOWER(ticker) LIKE :prefix OR LOWER(name) LIKE :prefix THEN 3
                WHEN LOWER(ticker) LIKE :contains OR LOWER(name) LIKE :contains THEN 4 ELSE 5 END AS match_rank,
              CASE WHEN LOWER(ticker) = :query THEN 'exact_ticker' WHEN cik = :cik THEN 'exact_cik'
                WHEN LOWER(name) = :query THEN 'exact_name'
                WHEN LOWER(ticker) LIKE :prefix OR LOWER(name) LIKE :prefix THEN 'prefix'
                WHEN LOWER(ticker) LIKE :contains OR LOWER(name) LIKE :contains THEN 'substring' ELSE 'fuzzy' END AS match_type,
              similarity(LOWER(COALESCE(name, '')), :query)::numeric(8,6) AS name_similarity
            FROM (#{source.sql(group)}) entities
            WHERE #{source.matching(name: 'name', ticker: 'ticker', cik: 'cik')}
          ) matches
        SQL
      end
    end
  end
end
