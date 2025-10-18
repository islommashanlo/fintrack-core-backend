# frozen_string_literal: true

class ApplicationController < ActionController::API
  include Authenticate

  # Only authenticate for API endpoints, not for health checks or auth endpoints
  before_action :authenticate_user!, unless: :devise_controller?
  skip_before_action :authenticate_user!, if: :health_check?
  before_action :configure_permitted_parameters, if: :devise_controller?

  rescue_from CanCan::AccessDenied do |exception|
    render json: { error: 'Access denied' }, status: :forbidden
  end

  private

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:email])
    devise_parameter_sanitizer.permit(:sign_in, keys: [:email])
  end

  def health_check?
    controller_name == 'health' || (controller_name == 'auth' && action_name == 'signup') || (controller_name == 'auth' && action_name == 'login')
  end

  def current_ability
    @current_ability ||= Ability.new(current_user)
  end
end
