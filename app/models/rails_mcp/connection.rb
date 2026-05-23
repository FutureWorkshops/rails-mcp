module RailsMcp
  # STI parent. Hosts subclass with their own type (e.g. BasecampConnection) and
  # add table columns via additive migrations on the shared `connections` table.
  class Connection < ApplicationRecord
    self.table_name = "connections"

    belongs_to :user, class_name: "RailsMcp::User"

    encrypts :access_token, :refresh_token

    validates :name,        presence: true
    validates :external_id, presence: true, uniqueness: { scope: :user_id }

    def token_expired?
      token_expires_at.nil? || token_expires_at <= 30.seconds.from_now
    end

    def needs_reconnect?
      !token_active? && token_refresh_failed_at.present?
    end

    def mark_refresh_failed!(error_code)
      update!(
        token_active: false,
        token_refresh_failed_at: Time.current,
        token_refresh_error: error_code
      )
    end

    def mark_refresh_succeeded!(access_token:, refresh_token:, expires_in:)
      update!(
        access_token: access_token,
        refresh_token: refresh_token,
        token_expires_at: Time.current + expires_in.to_i.seconds,
        token_active: true,
        token_refresh_failed_at: nil,
        token_refresh_error: nil
      )
    end
  end
end
