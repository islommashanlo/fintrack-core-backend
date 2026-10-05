# frozen_string_literal: true

module Ops
  class ValidationController < ActionController::Base
    include ActionController::HttpAuthentication::Basic::ControllerMethods

    layout "application"
    before_action :authenticate

    def show
      @form4_checks = ValidationReport.new.checks
      @form13f_checks = Validation13fReport.new.checks
    end

    private

    def authenticate
      authenticate_or_request_with_http_basic("FilingsIntel ops") { |user, password| OpsAuth.valid?(user, password) }
    end
  end
end
