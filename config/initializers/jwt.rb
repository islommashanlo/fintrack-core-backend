# frozen_string_literal: true

require 'jwt'
require 'net/http'
require 'json'

# JWT configuration for devise-jwt
Devise::JWT.config do |config|
  # Set the JWT secret key. In production, use Rails.application.credentials.jwt_secret
  config.secret = ENV.fetch('DEVISE_JWT_SECRET_KEY', 'your-super-secret-jwt-key-change-this-in-production')

  # Set the JWT algorithm. Defaults to HS256
  config.algorithm = 'HS256'

  # Set the JWT expiration time. Defaults to 1 hour
  config.expiration_time = 24.hours.to_i

  # Set the JWT request_formats. Defaults to [:json]
  config.request_formats = { api: [:json] }

  # Set the JWT revocation strategy. Defaults to :jwt_blacklist
  config.revocation_strategy = Devise::JWT::RevocationStrategies::Null

  # Set the JWT dispatcher. Defaults to :cookie
  config.dispatch_requests = [
    ['POST', %r{^/api/login$}],
    ['POST', %r{^/api/signup$}]
  ]

  # Set the JWT revocation requests. Defaults to [['DELETE', %r{^/api/logout$}] ]
  config.revocation_requests = [
    ['DELETE', %r{^/api/logout$}]
  ]
end
