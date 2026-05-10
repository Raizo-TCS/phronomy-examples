Rails.application.routes.draw do
  root "chat#index"
  post "chat/send", to: "chat#send_message"

  # ActionCable mount point
  mount ActionCable.server => "/cable"

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
