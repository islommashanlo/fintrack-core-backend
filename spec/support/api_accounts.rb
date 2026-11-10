# frozen_string_literal: true

module ApiAccounts
  def api_csrf
    get api_v1_auth_csrf_path, as: :json
    @api_csrf = response.parsed_body.fetch("data").fetch("csrf_token")
  end

  def api_headers
    { "X-CSRF-Token" => @api_csrf }
  end

  def api_login(user, password: "password123")
    api_csrf
    post api_v1_auth_login_path, params: { email: user.email_address, password: }, headers: api_headers, as: :json
    @api_csrf = response.parsed_body.fetch("data").fetch("csrf_token")
  end

  def with_api_csrf_protection
    previous = Api::V1::BaseController.allow_forgery_protection
    Api::V1::BaseController.allow_forgery_protection = true
    yield
  ensure
    Api::V1::BaseController.allow_forgery_protection = previous
  end

  def with_frontend_origin(origin)
    previous = ENV["FRONTEND_ORIGIN"]
    ENV["FRONTEND_ORIGIN"] = origin
    yield
  ensure
    ENV["FRONTEND_ORIGIN"] = previous
  end
end
