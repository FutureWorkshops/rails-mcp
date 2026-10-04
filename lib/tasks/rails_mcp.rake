namespace :rails_mcp do
  desc "Offboard a user: revoke all their MCP OAuth tokens and delete their provider connections. Usage: rails rails_mcp:revoke_user[email]"
  task :revoke_user, [ :email ] => :environment do |_task, args|
    email = args[:email].to_s.strip.downcase
    abort "Usage: rails rails_mcp:revoke_user[email]" if email.empty?

    user = RailsMcp::User.find_by(email: email)
    abort "No user with email #{email}" unless user

    tokens = Doorkeeper::AccessToken.where(resource_owner_id: user.id, revoked_at: nil).count
    RailsMcp::RefreshTokenPolicy.revoke_all_for_owner!(user.id)
    connections = user.connections.destroy_all.size

    puts "Revoked #{tokens} token(s) and deleted #{connections} connection(s) for #{email}."
  end
end
