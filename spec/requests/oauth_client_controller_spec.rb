require "rails_helper"

RSpec.describe RailsMcp::OauthClientController, type: :request do
  # Routed via spec/dummy/config/routes.rb → TestSsoController, a concrete
  # subclass that supplies the upstream URLs + credentials. Outbound HTTP is
  # stubbed at the controller level rather than via webmock, to keep the
  # engine free of an extra dev dependency.

  describe "GET /test_sso/connect" do
    it "redirects to the IdP authorize URL with the right query parameters" do
      get "/test_sso/connect"

      expect(response).to redirect_to(/\Ahttps:\/\/hub\.example\.test\/oauth\/authorize\?/)
      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      expect(query).to include(
        "response_type" => "code",
        "client_id"     => "test-client-id",
        "redirect_uri"  => "http://www.example.com/test_sso/callback",
        "scope"         => "openid"
      )
      expect(query["state"]).to match(/\A[a-f0-9]{32}\z/)
    end
  end

  describe "GET /test_sso/callback" do
    def stub_token_and_userinfo(sub:, email:, name:, accounts:, current_account_id: nil)
      allow_any_instance_of(TestSsoController).to receive(:exchange_code).and_return(access_token: "at-#{sub}")
      allow_any_instance_of(TestSsoController).to receive(:fetch_userinfo).and_return(
        "sub"                => sub,
        "email"              => email,
        "name"               => name,
        "accounts"           => accounts,
        "current_account_id" => current_account_id || accounts.first&.dig("id")
      )
    end

    def primed_state
      get "/test_sso/connect"
      Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")
    end

    it "creates a user + mirrored account, signs the user in, and redirects" do
      state = primed_state
      stub_token_and_userinfo(
        sub: "user-1", email: "matt@example.com", name: "Matt",
        accounts: [ { "id" => "100", "name" => "Acme" } ]
      )

      expect {
        get "/test_sso/callback", params: { code: "code", state: state }
      }.to change(RailsMcp::User, :count).by(1)
       .and change(RailsMcp::Account, :count).by(1)

      user = RailsMcp::User.find_by!(identity_id: "user-1")
      expect(user.email).to eq("matt@example.com")
      expect(user.account.cowork_account_id).to eq("100")
      expect(user.account.name).to eq("Acme")
      expect(user.role).to eq("member")
      expect(response).to redirect_to("/connections")
    end

    it "captures the role from the user's current account entry" do
      state = primed_state
      stub_token_and_userinfo(
        sub: "admin-1", email: "boss@example.com", name: "Boss",
        accounts: [
          { "id" => "100", "name" => "Acme", "role" => "admin" },
          { "id" => "200", "name" => "Other", "role" => "member" }
        ],
        current_account_id: "100"
      )

      get "/test_sso/callback", params: { code: "code", state: state }

      user = RailsMcp::User.find_by!(identity_id: "admin-1")
      expect(user.admin?).to be(true)
      expect(user.account.cowork_account_id).to eq("100")
    end

    it "refreshes the role on a returning user when it changes upstream" do
      account = RailsMcp::Account.create!(cowork_account_id: "100", name: "Acme")
      account.users.create!(identity_id: "user-4", email: "u@x.com", name: "U", role: "admin")

      state = primed_state
      stub_token_and_userinfo(
        sub: "user-4", email: "u@x.com", name: "U",
        accounts: [ { "id" => "100", "name" => "Acme", "role" => "member" } ]
      )

      get "/test_sso/callback", params: { code: "code", state: state }

      expect(RailsMcp::User.find_by!(identity_id: "user-4").role).to eq("member")
    end

    it "defaults an unrecognised role to member" do
      state = primed_state
      stub_token_and_userinfo(
        sub: "user-5", email: "weird@example.com", name: "W",
        accounts: [ { "id" => "100", "name" => "Acme", "role" => "superuser" } ]
      )

      get "/test_sso/callback", params: { code: "code", state: state }

      expect(RailsMcp::User.find_by!(identity_id: "user-5").role).to eq("member")
    end

    it "re-uses an existing mirrored account when a teammate signs in" do
      RailsMcp::Account.create!(cowork_account_id: "100", name: "Stale name")

      state = primed_state
      stub_token_and_userinfo(
        sub: "user-2", email: "newhire@example.com", name: "New",
        accounts: [ { "id" => "100", "name" => "Acme" } ]
      )

      expect {
        get "/test_sso/callback", params: { code: "code", state: state }
      }.to change(RailsMcp::User, :count).by(1)
       .and change(RailsMcp::Account, :count).by(0)

      account = RailsMcp::Account.find_by!(cowork_account_id: "100")
      expect(account.name).to eq("Acme")
      expect(account.users.pluck(:email)).to include("newhire@example.com")
    end

    it "moves the user to a new mirror when their current_account_id changes" do
      account = RailsMcp::Account.create!(cowork_account_id: "100", name: "Acme")
      account.users.create!(identity_id: "user-3", email: "m@x.com", name: "M")

      state = primed_state
      stub_token_and_userinfo(
        sub: "user-3", email: "m@x.com", name: "M",
        accounts: [ { "id" => "200", "name" => "Other Org" } ]
      )

      get "/test_sso/callback", params: { code: "code", state: state }

      user = RailsMcp::User.find_by!(identity_id: "user-3")
      expect(user.account.cowork_account_id).to eq("200")
    end

    it "rejects a mismatched state and does not create a user" do
      primed_state
      stub_token_and_userinfo(sub: "x", email: "x@x.com", name: "X", accounts: [])

      expect {
        get "/test_sso/callback", params: { code: "code", state: "bogus" }
      }.not_to change(RailsMcp::User, :count)
      expect(response).to redirect_to("/")
      expect(request.flash[:alert]).to match(/Invalid SSO state/)
    end

    it "rejects an absolute return_to and falls back to /connections" do
      state = primed_state
      stub_token_and_userinfo(
        sub: "z", email: "z@x.com", name: "Z",
        accounts: [ { "id" => "1", "name" => "Acme" } ]
      )

      allow_any_instance_of(ActionDispatch::Request::Session)
        .to receive(:[]).and_call_original
      allow_any_instance_of(ActionDispatch::Request::Session)
        .to receive(:[]).with(:return_to).and_return("//evil.example.com/steal")

      get "/test_sso/callback", params: { code: "code", state: state }
      expect(response).to redirect_to("/connections")
    end
  end
end
