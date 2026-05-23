class ApplicationController < ActionController::Base
  # Disable CSRF in the dummy app so request specs can POST without tokens; the
  # real Rails apps using this engine keep their own protect_from_forgery.
  skip_forgery_protection
end
