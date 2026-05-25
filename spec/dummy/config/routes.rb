Rails.application.routes.draw do
  mount RailsMcp::Engine => "/"
  use_doorkeeper

  root to: "sessions#new"

  # Dummy sign-in stub for specs.
  get  "sign_in",      to: "sessions#new", as: :sign_in
  post "test_sign_in", to: "sessions#test_sign_in"

  # Concrete subclass of RailsMcp::OauthClientController for spec coverage.
  get "test_sso/connect",  to: "test_sso#connect",  as: :test_sso_connect
  get "test_sso/callback", to: "test_sso#callback", as: :test_sso_callback
end
