# frozen_string_literal: true

module Api
  module V1
    class InsiderClustersParameters
      PARAMETERS = %w[direction ticker issuer_cik min_insiders min_value date_from date_to watchlist_only sort limit cursor].freeze

      def self.normalize(values)
        dates = ActivityParameters.normalize(values.slice("date_from", "date_to", "min_value", "watchlist_only"))
        values = values.merge(dates.except("type"))
        values["direction"] ||= "all"
        values["min_insiders"] ||= ActivityMethodology.minimum_insiders.to_s
        invalid!("direction") unless %w[all purchase sale].include?(values["direction"])
        if values["ticker"]
          values["ticker"] = values["ticker"].upcase
          invalid!("ticker") unless values["ticker"].match?(/\A[A-Z0-9][A-Z0-9.-]{0,19}\z/)
        end
        invalid!("issuer_cik") if values["issuer_cik"] && !values["issuer_cik"].match?(/\A\d{10}\z/)
        unless values["min_insiders"].match?(/\A\d{1,4}\z/) &&
            values["min_insiders"].to_i.between?(ActivityMethodology.minimum_insiders, 1000)
          invalid!("min_insiders")
        end
        values["min_insiders"] = values["min_insiders"].to_i.to_s
        values
      end

      def self.invalid!(key)
        raise InvalidParameter, "Invalid #{key} parameter"
      end
      private_class_method :invalid!
    end
  end
end
