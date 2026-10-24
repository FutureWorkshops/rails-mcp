class SessionsController < ApplicationController
  def new
    render plain: "sign in"
  end

  # Test-only: start a session for a user, bypassing identity-provider OAuth.
  # Specs hit POST /test_sign_in?user_id=… before the request under test;
  # `signed_in_at` (epoch seconds) backdates the session, and
  # `legacy=1` writes a pre-1.0 session with no sign-in stamp.
  def test_sign_in
    if params[:legacy].present?
      session[:user_id] = params[:user_id].to_i
    else
      now = params[:signed_in_at].present? ? Time.zone.at(params[:signed_in_at].to_i) : Time.current
      RailsMcp::Authentication.start_session(session, RailsMcp::User.find(params[:user_id]), now: now)
    end
    head :ok
  end

  # Test-only: reports who the session resolves to.
  def protected_page
    render plain: current_user ? "hello #{current_user.email}" : "nobody"
  end
end
