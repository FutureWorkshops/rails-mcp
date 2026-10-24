require "rails_helper"

RSpec.describe RailsMcp::IdentityCheck do
  let(:fw) { RailsMcp::Account.create!(name: "Future Workshops", groundwork_account_id: "100") }
  let(:user) { fw.users.create!(email: "u@example.com", identity_id: "gw-1", role: "admin") }

  def standing(status = :active, accounts: nil, home: nil, reason: nil)
    RailsMcp::IdentityStanding.new(status, accounts: accounts, home_account_id: home, reason: reason)
  end

  describe ".reconcile!" do
    it "downgrades the role in place when the user was demoted" do
      outcome = described_class.reconcile!(user, standing(accounts: [ { "id" => "100", "name" => "Future Workshops", "role" => "member" } ]))

      expect(outcome).to eq(:active)
      expect(user.reload.role).to eq("member")
      expect(user.account).to eq(fw)
    end

    it "keeps the mirrored account while the user is still a member of it, even if it isn't home" do
      outcome = described_class.reconcile!(user, standing(home: "200", accounts: [
        { "id" => "200", "name" => "Client", "role" => "member" },
        { "id" => "100", "name" => "Future Workshops", "role" => "admin" }
      ]))

      expect(outcome).to eq(:active)
      expect(user.reload.account).to eq(fw)
      expect(user.role).to eq("admin")
    end

    it "moves a user removed from the mirrored account to their home account, with that account's role" do
      outcome = described_class.reconcile!(user, standing(home: "300", accounts: [
        { "id" => "200", "name" => "Client", "role" => "admin" },
        { "id" => "300", "name" => "Home Org", "role" => "member" }
      ]))

      expect(outcome).to eq(:active)
      user.reload
      expect(user.account.groundwork_account_id).to eq("300")
      expect(user.account.name).to eq("Home Org")
      expect(user.role).to eq("member")
    end

    it "falls back to the first account when the home account isn't listed" do
      described_class.reconcile!(user, standing(home: "999", accounts: [ { "id" => "200", "name" => "Client", "role" => "weird" } ]))

      expect(user.reload.account.groundwork_account_id).to eq("200")
      expect(user.role).to eq("member")
    end

    it "is inactive when the user is a member of nothing" do
      expect(described_class.reconcile!(user, standing(accounts: []))).to eq(:inactive)
    end

    it "leaves role and account alone when no memberships were sent" do
      expect(described_class.reconcile!(user, standing)).to eq(:active)
      expect(user.reload.role).to eq("admin")
    end

    it "passes inactive and unknown through without touching the user" do
      expect(described_class.reconcile!(user, standing(:inactive))).to eq(:inactive)
      expect(described_class.reconcile!(user, standing(:unknown))).to eq(:unknown)
      expect(user.reload.role).to eq("admin")
    end
  end

  describe ".check" do
    it "is unchecked with no identity_status hook" do
      expect(described_class.check(user)).to eq([ :unchecked, nil ])
    end

    it "accepts a bare symbol from a pre-1.0 hook" do
      RailsMcp.config.identity_status = ->(_user) { :inactive }
      expect(described_class.check(user).first).to eq(:inactive)
    end

    it "fails closed if the local update itself fails" do
      RailsMcp.config.identity_status = ->(_user) {
        RailsMcp::IdentityStanding.new(:active, accounts: [ { "id" => "100", "name" => "FW", "role" => "member" } ])
      }
      allow(RailsMcp::Account).to receive(:find_or_initialize_by).and_raise(ActiveRecord::StatementInvalid, "db down")

      outcome, standing = described_class.check(user)
      expect(outcome).to eq(:unknown)
      expect(standing.reason).to include("StatementInvalid")
    end

    it "applies a demotion even when the user row fails an unrelated validation" do
      user.update_column(:email, "not an email")
      described_class.reconcile!(user, standing(accounts: [ { "id" => "100", "name" => "FW", "role" => "member" } ]))
      expect(user.reload.role).to eq("member")
    end

    it "treats a hook that raises as unknown" do
      RailsMcp.config.identity_status = ->(_user) { raise "boom" }
      outcome, standing = described_class.check(user)
      expect(outcome).to eq(:unknown)
      expect(standing.reason).to include("boom")
    end
  end

  describe ".deactivate!" do
    let(:app) { Doorkeeper::Application.create!(name: "C", redirect_uri: "https://claude.ai/api/mcp/auth_callback", scopes: "read write", confidential: false) }

    it "revokes every token and runs the host hook" do
      token = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: user.id, scopes: "read", expires_in: 60)
      seen = nil
      RailsMcp.config.on_user_deactivated = ->(u) { seen = u }

      described_class.deactivate!(user, reason: "spec")

      expect(token.reload).to be_revoked
      expect(seen).to eq(user)
    end

    it "still revokes, and reports, when the hook fails" do
      token = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: user.id, scopes: "read", expires_in: 60)
      RailsMcp.config.on_user_deactivated = ->(_u) { raise "upstream down" }
      allow(Rails.error).to receive(:report)

      described_class.deactivate!(user, reason: "spec")

      expect(token.reload).to be_revoked
      expect(Rails.error).to have_received(:report).with(instance_of(RuntimeError), hash_including(handled: true))
    end
  end
end

RSpec.describe RailsMcp::IdentityStanding do
  it "wraps the shapes a host hook can return" do
    expect(described_class.wrap(nil)).to be_nil
    expect(described_class.wrap(:active)).to be_active
    expect(described_class.wrap("inactive")).to be_inactive
    standing = described_class.new(:unknown)
    expect(described_class.wrap(standing)).to be(standing)
    expect { described_class.wrap(42) }.to raise_error(ArgumentError)
    expect { described_class.new(:maybe) }.to raise_error(ArgumentError)
  end

  it "compares equal to its status symbol" do
    expect(described_class.new(:active)).to eq(:active)
    expect(described_class.new(:active)).not_to eq(:inactive)
    expect(described_class.new(:active).to_sym).to eq(:active)
  end
end
