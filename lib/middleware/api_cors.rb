# frozen_string_literal: true

require "uri"
require "json"

module Middleware
  class ApiCors
    METHODS = %w[GET HEAD POST PATCH DELETE OPTIONS].freeze
    HEADERS = %w[content-type x-csrf-token accept].freeze
    EXPOSED_HEADERS = %w[Retry-After Content-Disposition X-Export-Row-Count X-Export-Total-Count
      X-Export-Has-More X-Export-Next-Cursor X-Export-As-Of X-Export-Sort X-Export-Row-Limit].freeze

    def self.origin
      value = ENV["FRONTEND_ORIGIN"]
      return if value.nil? || value.empty?

      uri = URI.parse(value)
      unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo &&
          !uri.query && !uri.fragment && [ "", "/" ].include?(uri.path)
        raise ArgumentError, "FRONTEND_ORIGIN must be one HTTP(S) origin"
      end
      port = uri.port == uri.default_port ? "" : ":#{uri.port}"
      "#{uri.scheme}://#{uri.host.downcase}#{port}"
    rescue URI::InvalidURIError
      raise ArgumentError, "FRONTEND_ORIGIN must be one HTTP(S) origin"
    end

    def initialize(app)
      @app = app
      self.class.origin
    end

    def call(env)
      return @app.call(env) unless env["PATH_INFO"].start_with?("/api/v1/")

      origin = env["HTTP_ORIGIN"]
      allowed = origin && self.class.origin && origin == self.class.origin
      if env["REQUEST_METHOD"] == "OPTIONS"
        requested_headers = env.fetch("HTTP_ACCESS_CONTROL_REQUEST_HEADERS", "").downcase.split(",").map(&:strip)
        unless allowed && METHODS.include?(env["HTTP_ACCESS_CONTROL_REQUEST_METHOD"]) && (requested_headers - HEADERS).empty?
          return [ 403, { "content-type" => "application/json", "vary" => "Origin" },
                   [ JSON.generate(error: { code: "ORIGIN_NOT_ALLOWED", message: "Origin or preflight is not allowed" }) ] ]
        end
        return [ 204, cors_headers(origin).merge("access-control-allow-methods" => METHODS.join(", "),
                   "access-control-allow-headers" => HEADERS.join(", "), "access-control-max-age" => "600"), [] ]
      end
      status, headers, body = @app.call(env)
      headers = headers.dup
      headers["vary"] = (headers.fetch("vary", "").split(",").map(&:strip) + [ "Origin" ]).reject(&:empty?).uniq.join(", ")
      headers.merge!(cors_headers(origin).except("vary")) if allowed
      [ status, headers, body ]
    end

    private

    def cors_headers(origin)
      { "access-control-allow-origin" => origin, "access-control-allow-credentials" => "true",
        "access-control-expose-headers" => EXPOSED_HEADERS.join(", "), "vary" => "Origin" }
    end
  end
end
