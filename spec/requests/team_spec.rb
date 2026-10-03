require "rails_helper"

RSpec.describe "Team management", type: :request do
  let(:account) do
    a = RailsMcp::Account.create!(name: "Acme")
    a.mark_onboarded!
    a
  end
  let(:user) { account.users.create!(email: "host@example.com", identity_id: "host") }

  before { sign_in_as(user) }

  describe "GET /team" do
    it "lists members and pending invitations" do
      account.users.create!(email: "teammate@example.com", identity_id: "tm")
      pending = account.invitations.create!(email: "guest@example.com", invited_by: user)
      account.invitations.create!(email: "old@example.com", invited_by: user, accepted_at: Time.current)

      get "/team"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("host@example.com", "teammate@example.com", "guest@example.com")
      expect(response.body).not_to include("old@example.com")
    end
  end

  describe "POST /team/invitations" do
    it "creates invitation and enqueues mailer" do
      expect {
        post "/team/invitations", params: { email: "new@example.com" }
      }.to change(RailsMcp::Invitation, :count).by(1)

      expect(ActionMailer::Base.deliveries.size).to eq(0)
      perform_enqueued_jobs { ActionMailer::Base.deliveries }
      # Mailer is enqueued, not delivered synchronously. Confirm a job is on the queue.
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs).not_to be_empty
    end

    it "rejects blank email" do
      expect { post "/team/invitations", params: { email: "" } }
        .not_to change(RailsMcp::Invitation, :count)
      follow_redirect!
      expect(flash[:alert]).to include("required")
    end

    it "rejects existing member" do
      expect { post "/team/invitations", params: { email: "HOST@example.com" } }
        .not_to change(RailsMcp::Invitation, :count)
    end

    it "rejects duplicate pending invitation" do
      account.invitations.create!(email: "dup@example.com", invited_by: user)
      expect { post "/team/invitations", params: { email: "dup@example.com" } }
        .not_to change(RailsMcp::Invitation, :count)
    end
  end

  describe "PATCH /team/account" do
    it "updates the account name" do
      patch "/team/account", params: { name: "New Name" }
      expect(account.reload.name).to eq("New Name")
    end
  end

  describe "DELETE /team/invitations/:id" do
    it "revokes a pending invitation" do
      inv = account.invitations.create!(email: "x@example.com", invited_by: user)
      delete "/team/invitations/#{inv.id}"
      expect(inv.reload).to be_revoked
    end

    it "404s for invitations belonging to another account" do
      other_account = RailsMcp::Account.create!(name: "Other")
      other_account.mark_onboarded!
      other_user = other_account.users.create!(email: "other@example.com", identity_id: "other")
      inv = other_account.invitations.create!(email: "z@example.com", invited_by: other_user)

      delete "/team/invitations/#{inv.id}"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "admin-only changes" do
    before do
      account.users.create!(email: "admin@example.com", identity_id: "adm", role: "admin")
    end

    it "lets an admin invite" do
      user.update!(role: "admin")
      expect { post "/team/invitations", params: { email: "new@example.com" } }
        .to change(RailsMcp::Invitation, :count).by(1)
    end

    it "stops a member from inviting, renaming or revoking when the account has an admin" do
      invite = account.invitations.create!(email: "guest@example.com", invited_by: user)

      expect { post "/team/invitations", params: { email: "new@example.com" } }
        .not_to change(RailsMcp::Invitation, :count)
      expect(flash[:alert]).to match(/Only workspace admins/)

      patch "/team/account", params: { name: "Pwned" }
      expect(account.reload.name).to eq("Acme")

      delete "/team/invitations/#{invite.id}"
      expect(invite.reload).to be_pending
    end

    it "hides the management controls from members" do
      get "/team"
      expect(response.body).not_to include("Send invite")
      expect(response.body).to include("Only workspace admins")
    end
  end

  it "rejects an over-long workspace name" do
    patch "/team/account", params: { name: "x" * 101 }
    expect(account.reload.name).to eq("Acme")
  end
end
