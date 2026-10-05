# frozen_string_literal: true

module Api
  module V1
    class FilingsController < BaseController
      def show
        filing = Filing.includes(:insider_transactions, institutional_report: :institutional_holdings)
                       .find_by!(accession_no: params[:accession])

        render json: { data: FilingSerializer.render(filing, as_of:) }
      end
    end
  end
end
