class ApplicationController < ActionController::API
  include Authenticate

  before_action :authenticate_user!
end


