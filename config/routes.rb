Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "videos#index"

  get "signup", to: "users#new", as: :signup
  post "signup", to: "users#create"
  get "login", to: "sessions#new", as: :login
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy", as: :logout

  get "integrations", to: "integrations#show", as: :integrations
  get "integrations/instagram/connect", to: "integrations#instagram_connect", as: :instagram_connect
  get "integrations/instagram/callback", to: "integrations#instagram_callback", as: :instagram_callback
  post "integrations/instagram/:id/sync", to: "integrations#instagram_sync", as: :instagram_sync
  delete "integrations/instagram/:id", to: "integrations#instagram_disconnect", as: :instagram_disconnect

  resources :videos, only: %i[index new create show] do
    resources :preview_artifacts, only: :show
  end
end
