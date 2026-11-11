# frozen_string_literal: true

module Api
  module V1
    class FundComparisonsController < BaseController
      prepend_before_action :private_response!

      def show
        values = read_parameters(allowed: %w[ciks period scope cusip put_call share_type sort limit cursor])
        require_parameters!(values, "ciks")
        raise InvalidParameter, "Invalid ciks parameter" if values.fetch("ciks").bytesize > 200
        ciks = values.fetch("ciks").split(",", -1).map(&:strip)
        unless ciks.all? { |cik| cik.match?(/\A\d{10}\z/) } && ciks.uniq.size.between?(2, 10)
          raise InvalidParameter, "Use 2 to 10 distinct 10-digit CIKs"
        end
        values["ciks"] = ciks.uniq.sort.join(",")
        values["scope"] ||= "all"
        raise InvalidParameter, "Invalid scope parameter" unless %w[all shared differing_moves].include?(values["scope"])
        InstitutionalHoldingsQuery.validate_filters!(values)
        period = period_parameter(values["period"])
        limits = PlanCatalog::PLANS.fetch(PlanCatalog.for_user(Current.user))
        maximum, history = limits.values_at(:fund_compare, :history_quarters)
        raise PlanCatalog::Required.new(feature: "fund_compare", limit: maximum) if maximum && ciks.uniq.size > maximum
        page = CursorPage.new(parameters: values, context: { "resource" => "fund_comparison", "user_id" => Current.user&.id,
          "maximum_funds" => maximum, "history_quarters" => history }, sorts: FundComparisonQuery::SORTS,
          default_sort: "-holders", bounds: FundComparisonQuery::BOUNDS, as_of:)
        render json: FundComparisonQuery.new(page:, filters: values, period:, history_quarters: history).call
      end
    end
  end
end
