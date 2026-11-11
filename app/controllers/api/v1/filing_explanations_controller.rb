# frozen_string_literal: true

module Api
  module V1
    class FilingExplanationsController < BaseController
      before_action :private_response!

      def create
        read_parameters(allowed: [], path_keys: [ :accession ])
        ApiRateLimiter.check!(scope: "explanations", identifier: request.remote_ip, limit: 30, window: 1.hour)
        filing = Filing.find_by!(accession_no: params[:accession])
        result = FilingExplanations::Generate.call(filing:)
        render json: { data: FilingExplanationSerializer.render(result.explanation, as_of:), meta: { cached: result.cached } }
      rescue FilingExplanations::Generate::NotReady
        render json: { error: { code: "FILING_NOT_READY", message: "Normalized filing data is not ready" } }, status: :conflict
      rescue FilingExplanations::Generate::Unsupported
        render json: { error: { code: "EXPLANATION_UNSUPPORTED", message: "This filing format is not supported" } }, status: :unprocessable_entity
      end
    end
  end
end
