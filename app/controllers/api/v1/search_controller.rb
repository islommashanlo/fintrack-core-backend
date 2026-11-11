# frozen_string_literal: true

module Api
  module V1
    class SearchController < BaseController
      def index
        values = read_parameters(allowed: %w[q type sort limit cursor])
        require_parameters!(values, "q")
        query = values.fetch("q")
        unless query.valid_encoding? && query.bytesize <= 400 && !query.match?(/[[:cntrl:]]/)
          raise InvalidParameter, "Invalid q parameter"
        end
        values["q"] = query.gsub(/[[:space:]]+/, " ").strip
        unless values["q"].length.between?(1, 100)
          raise InvalidParameter, "Invalid q parameter"
        end
        type = values.fetch("type", "all")
        raise InvalidParameter, "Invalid type parameter" unless [ "all", *SearchQuery::GROUPS ].include?(type)
        raise InvalidParameter, "Invalid sort parameter" if values["sort"] && values["sort"] != "relevance"
        raise InvalidParameter, "A cursor requires one search type" if values["cursor"] && type == "all"
        if values["limit"] && !values["limit"].match?(/\A(?:[1-9]|1[0-9]|20)\z/)
          raise InvalidParameter, "Invalid limit parameter"
        end
        values["limit"] ||= "5"
        render json: SearchQuery.new(parameters: values, as_of:).call
      end
    end
  end
end
