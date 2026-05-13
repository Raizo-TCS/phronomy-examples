Rails.application.routes.draw do
  root "scans#index"

  resources :scans, only: %i[index create show] do
    member do
      post :approve
      post :note
      post :followup
    end
  end

  mount ActionCable.server => "/cable"

  get "up" => "rails/health#show", as: :rails_health_check
end
