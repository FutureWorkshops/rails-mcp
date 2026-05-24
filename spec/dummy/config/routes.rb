Rails.application.routes.draw do
  mount RailsMcp::Engine => "/"
  use_doorkeeper

  # Dummy sign-in stub for specs.
  get  "sign_in",      to: "sessions#new", as: :sign_in
  post "test_sign_in", to: "sessions#test_sign_in"
end
