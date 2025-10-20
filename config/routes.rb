Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  resources :builds, only: [:new, :show], param: :id do
    collection do
      post :lookup
    end
  end

  root "builds#new"
end
