Rails.application.routes.draw do
  root "conversations#index"
  post   "conversations",     to: "conversations#create",  as: :new_conversation
  delete "conversations/:id", to: "conversations#destroy", as: :conversation
  post   "messages",          to: "messages#create",       as: :messages
  post   "summaries",         to: "summaries#create",      as: :summaries

  get "up" => "rails/health#show", as: :rails_health_check
end
