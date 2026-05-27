# Concrete subclass of RailsMcp::OauthClientController used only by
# spec/requests/oauth_client_controller_spec.rb. Keeps the upstream URLs
# and credentials accessors in one place so the spec can stub them.
class TestSsoController < RailsMcp::OauthClientController
  def self.authorize_url = "https://hub.example.test/oauth/authorize"
  def self.token_url     = "https://hub.example.test/oauth/token"
  def self.userinfo_url  = "https://hub.example.test/oauth/userinfo"
  def self.client_id     = "test-client-id"
  def self.client_secret = "test-client-secret"
  def self.redirect_uri  = "http://www.example.com/test_sso/callback"
end
