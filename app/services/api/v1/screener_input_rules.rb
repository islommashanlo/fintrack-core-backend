# frozen_string_literal: true

module Api
  module V1
    module ScreenerInputRules
      MAX_FILTERS = 20
      MIN_LIST_ITEMS = 1
      MAX_LIST_ITEMS = 20
      BETWEEN_ITEMS = 2
      MAX_TEXT_LENGTH = 200
      MAX_DECIMAL_BYTES = 128
      MAX_COUNT = 9_223_372_036_854_775_807
      PERCENTAGE_RANGE = (0..100).freeze
      PAGE_RANGE = (1..100).freeze
      DEFAULT_PAGE_SIZE = 50
      MAX_CURSOR_BYTES = 8192
      PATTERNS = {
        count: "[0-9]{1,20}", decimal: "-?[0-9]+(?:\\.[0-9]+)?",
        date: "[0-9]{4}-[0-9]{2}-[0-9]{2}", cik: "[0-9]{10}",
        ticker: "[A-Za-z0-9][A-Za-z0-9.-]{0,19}"
      }.freeze
      MATCHERS = PATTERNS.transform_values { |source| Regexp.new("\\A(?:#{source})\\z") }.freeze

      def self.constraints(type)
        case type
        when :count
          { input_types: %w[integer string], minimum: "0", maximum: MAX_COUNT.to_s, pattern: "^#{PATTERNS.fetch(type)}$" }
        when :decimal, :percentage
          result = { input_types: %w[number string], max_bytes: MAX_DECIMAL_BYTES, finite: true,
            pattern: "^#{PATTERNS.fetch(:decimal)}$" }
          result.merge!(minimum: PERCENTAGE_RANGE.begin.to_s, maximum: PERCENTAGE_RANGE.end.to_s) if type == :percentage
          result
        when :date
          { input_types: %w[string], pattern: "^#{PATTERNS.fetch(type)}$", format: "gregorian_date",
            minimum: "0001-01-01", maximum: "9999-12-31" }
        when :boolean
          { input_types: %w[boolean] }
        when :fund_coverage, :fund_report_type
          { input_types: %w[string] }
        else
          result = { input_types: %w[string], max_length: MAX_TEXT_LENGTH, non_blank: true, excludes_null_character: true }
          result[:pattern] = "^#{PATTERNS.fetch(type)}$" if PATTERNS.key?(type)
          result[:normalization] = "uppercase" if type == :ticker
          result
        end
      end

      def self.limits
        { max_filters: MAX_FILTERS, min_list_items: MIN_LIST_ITEMS, max_list_items: MAX_LIST_ITEMS,
          between_items: BETWEEN_ITEMS, between_order: "ascending", null_value: "omit_or_null",
          page_min: PAGE_RANGE.begin, page_max: PAGE_RANGE.end, page_default: DEFAULT_PAGE_SIZE, max_cursor_bytes: MAX_CURSOR_BYTES }
      end
    end
  end
end
