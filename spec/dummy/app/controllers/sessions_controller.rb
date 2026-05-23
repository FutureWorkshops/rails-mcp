class SessionsController < ApplicationController
  def new
    render plain: "sign in"
  end

  # Test-only: write a user id into the session, bypassing identity-provider OAuth.
  # Specs hit POST /test_sign_in?user_id=… before the request under test.
  def test_sign_in
    session[:user_id] = params[:user_id].to_i
    head :ok
  end
end
