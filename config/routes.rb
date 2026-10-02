# frozen_string_literal: true

require "sidekiq/web"
require "sidekiq/cron/web"

# Sidekiq Web is always behind HTTP basic auth; with OPS_USERNAME and OPS_PASSWORD unset it admits nobody.
Sidekiq::Web.use(Rack::Auth::Basic, "FilingsIntel ops") { |user, password| OpsAuth.valid?(user, password) }

Rails.application.routes.draw do
  root "dashboard#index"
  get "discover" => "discover#index"
  get "institutions/:cik" => "institutions#show", as: :institution, constraints: { cik: /\d{10}/ }
  get "insiders/:cik" => "insiders#show", as: :insider, constraints: { cik: /\d{10}/ }
  get "tickers/:ticker" => "tickers#show", as: :ticker, constraints: { ticker: /[A-Za-z0-9.-]+/ }

  # Liveness: 200 if the app boots. Used by load balancers and uptime monitors.
  get "up" => "rails/health#show", as: :rails_health_check

  # Readiness: also checks Postgres and Redis.
  get "health" => "health#show"

  namespace :ops do
    get "metrics" => "metrics#show"
  end

  mount Sidekiq::Web => "/sidekiq"
end
