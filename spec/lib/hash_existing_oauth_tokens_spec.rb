require "rails_helper"
require Rails.root.join("../../db/migrate/20261004100000_hash_existing_oauth_tokens").to_s

RSpec.describe HashExistingOauthTokens do
  let(:app) { Doorkeeper::Application.create!(name: "C", redirect_uri: "https://claude.ai/cb", scopes: "read", confidential: false) }

  it "hashes plain-text tokens the way Doorkeeper does and leaves hashed ones alone" do
    plain = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: 1, scopes: "read", expires_in: 3600)
    plain.update_columns(token: "plain-access", refresh_token: "plain-refresh")
    hashed = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: 1, scopes: "read", expires_in: 3600)
    already = hashed.reload.token

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(plain.reload.token).to eq(Digest::SHA256.hexdigest("plain-access"))
    expect(plain.refresh_token).to eq(Digest::SHA256.hexdigest("plain-refresh"))
    expect(hashed.reload.token).to eq(already)
    expect(Doorkeeper::AccessToken.by_token("plain-access")).to eq(plain)
  end
end
