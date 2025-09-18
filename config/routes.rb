Rails.application.routes.draw do
  get "/", to: "health#index"
  get "/health", to: "health#health"
  require "sidekiq/web"
  mount Sidekiq::Web => "/sidekiq"
  namespace :api do
    resources :traders, only: [:index, :show] do
      collection do
        get :politicians
        get :hedge_funds
        get :most_active
      end
    end
    resources :trades, only: [:index, :show] do
      collection do
        get :recent
        get :search
      end
    end
    get "profiles/:trader_id", to: "profiles#show"
    get "profiles/:trader_id/stats", to: "profiles#stats"
    get "stats", to: "stats#index"
    get "stats/by-type", to: "stats#by_type"
    get "stats/timeline", to: "stats#timeline"
    get "stats/biggest-trades", to: "stats#biggest_trades"
    resources :alerts, only: [:index, :create, :show, :update, :destroy]
    post "ingest/trades", to: "ingest#trades"
  end
end


