# frozen_string_literal: true

module Api
  module V1
    class ProtectedController < BaseController
      prepend_before_action :private_response!
      before_action :require_authentication
    end
  end
end
