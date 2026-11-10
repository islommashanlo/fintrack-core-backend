# frozen_string_literal: true

require "sidekiq/web"
require "sidekiq/cron/web"

# Sidekiq Web is always behind HTTP basic auth; with OPS_USERNAME and OPS_PASSWORD unset it admits nobody.
Sidekiq::Web.use(Rack::Auth::Basic, "FilingsIntel ops") { |user, password| OpsAuth.valid?(user, password) }

Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      get "auth/csrf" => "auth#csrf"
      post "auth/signup" => "auth#signup"
      post "auth/login" => "auth#login"
      delete "auth/logout" => "auth#logout"
      get "plans" => "plans#index", as: :plans
      get "me" => "accounts#show", as: :me
      patch "me" => "accounts#update"
      delete "me" => "accounts#destroy"
      get "watchlist" => "watchlist#index", as: :watchlist
      post "watchlist" => "watchlist#create"
      delete "watchlist" => "watchlist#destroy"
      delete "watchlist/:id" => "watchlist#destroy", as: :watchlist_item
      get "activity" => "activity#index", as: :activity
      get "activity/:id" => "activity#show", as: :activity_event
      get "methodology" => "methodology#show", as: :methodology
      post "screener/run" => "screener#run", as: :screener_run
      get "alert-rules" => "alert_rules#index", as: :alert_rules
      patch "alert-rules/:id" => "alert_rules#update", as: :alert_rule
      get "alert-events" => "alert_events#index", as: :alert_events
      resources :funds, param: :cik, only: %i[index show] do
        get :holdings, on: :member
        get :history, on: :member
        get :changes, on: :member
      end
      resources :companies, param: :ticker, only: :show, constraints: { ticker: /[A-Za-z0-9.-]+/ } do
        get :insiders, on: :member
        get :filings, on: :member
        get :institutional, on: :member
      end
      get "insiders/transactions" => "insider_transactions#index", as: :insider_transactions
      get "insiders/clusters" => "insider_clusters#index", as: :insider_clusters
      resources :insiders, param: :cik, only: :show do
        get :transactions, on: :member
        get :companies, on: :member
      end
      get "filings/:accession" => "filings#show", as: :filing,
          constraints: { accession: /\d{10}-\d{2}-\d{6}/ }
    end
  end

  resource :session
  resources :passwords, param: :token
  get "signup" => "users#new", as: :signup
  post "signup" => "users#create"
  get "alerts" => "alerts#index", as: :alerts
  resources :alert_rules, only: :update
  get "filings/:accession_no" => "filings#show", as: :filing,
      constraints: { accession_no: /\d{10}-\d{2}-\d{6}/ }
  get "watchlist" => "watchlist#index", as: :watchlist
  resources :follows, only: %i[create destroy]
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
    get "validation" => "validation#show"
  end

  mount Sidekiq::Web => "/sidekiq"
end
