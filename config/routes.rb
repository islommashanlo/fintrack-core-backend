# frozen_string_literal: true

Rails.application.routes.draw do
  mount RailsAdmin::Engine => '/admin', as: 'rails_admin'
  devise_for :users
  get '/', to: 'health#index'
  get '/health', to: 'health#health'
  require 'sidekiq/web'
  mount Sidekiq::Web => '/sidekiq'

  # Authentication routes
  post '/api/signup', to: 'api/auth#signup'
  post '/api/login',  to: 'api/auth#login'
  delete '/api/logout', to: 'api/auth#logout'

  namespace :api do
    # Traders (politicians, hedge funds, insiders, institutions, HNWIs)
    resources :traders, only: %i[index show] do
      collection do
        get :politicians
        get :hedge_funds
        get :most_active
        get :institutions
        get :hnwis
      end
    end

    # Trades
    resources :trades, only: %i[index show] do
      collection do
        get :recent
        get :search
      end
    end

    # Institutional holdings (13F snapshots)
    resources :institutional_holdings, only: %i[index show] do
      collection do
        get :by_ticker
        get :top_holders
      end
    end

    # Profiles and stats
    get 'profiles/:trader_id',       to: 'profiles#show'
    get 'profiles/:trader_id/stats', to: 'profiles#stats'
    get 'stats',                     to: 'stats#index'
    get 'stats/by-type',             to: 'stats#by_type'
    get 'stats/timeline',            to: 'stats#timeline'
    get 'stats/biggest-trades',      to: 'stats#biggest_trades'

    # Alert preferences and subscriptions
    get 'alert_preferences/index'
    get 'alert_preferences/create'
    get 'alert_preferences/show'
    get 'alert_preferences/update'
    get 'alert_preferences/destroy'
    resources :alert_preferences, only: %i[index create show update destroy]
    resources :subscriptions,     only: %i[index create show update destroy]
    get 'subscription_plans/index'
    resources :subscription_plans, only: [:index]

    # Ingest endpoints (scraper → backend)
    post 'ingest/trades',                  to: 'ingest#trades'
    post 'ingest/institutional_holdings',  to: 'ingest#institutional_holdings'

    # Stripe
    post 'stripe/webhooks', to: 'stripe#webhooks'
  end
end
