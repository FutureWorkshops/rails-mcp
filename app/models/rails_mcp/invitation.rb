module RailsMcp
  class Invitation < ApplicationRecord
    self.table_name = "invitations"

    SESSION_KEY = :rails_mcp_pending_invite_token
    EXPIRY_WINDOW = 14.days

    belongs_to :account,    class_name: "RailsMcp::Account"
    belongs_to :invited_by, class_name: "RailsMcp::User", optional: true

    validates :email,      presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :token,      presence: true, uniqueness: true
    validates :expires_at, presence: true

    normalizes :email, with: ->(e) { e.strip.downcase }

    before_validation :generate_token, on: :create
    before_validation :set_default_expiry, on: :create

    scope :pending, -> {
      where(accepted_at: nil, revoked_at: nil).where("expires_at > ?", Time.current)
    }

    def pending?
      accepted_at.nil? && revoked_at.nil? && expires_at > Time.current
    end

    def accepted?
      accepted_at.present?
    end

    def revoked?
      revoked_at.present?
    end

    def expired?
      !accepted? && !revoked? && expires_at <= Time.current
    end

    def claimable_by?(candidate_email)
      pending? && email.casecmp(candidate_email.to_s.strip).zero?
    end

    def accept!
      update!(accepted_at: Time.current) unless accepted?
    end

    def revoke!
      update!(revoked_at: Time.current) unless revoked?
    end

    # Pulls the pending invite token out of the session, validates it against
    # the candidate email, and returns the matching Invitation (or nil).
    # Yields a symbol on validation failures so the host controller can decide
    # how to redirect/flash:
    #
    #   RailsMcp::Invitation.consume_from_session!(session, candidate_email: email) do |error|
    #     case error
    #     when :unknown        then redirect_to root_path, alert: "Invite link is no longer valid."
    #     when :not_pending    then redirect_to invitation_path(token: token)
    #     when :email_mismatch then redirect_to root_path, alert: "Signed in as wrong email."
    #     end
    #   end
    def self.consume_from_session!(session, candidate_email:)
      token = session.delete(SESSION_KEY)
      return nil if token.blank?

      invitation = find_by(token: token)
      error =
        if    invitation.nil?                                then :unknown
        elsif !invitation.pending?                           then :not_pending
        elsif !invitation.claimable_by?(candidate_email)     then :email_mismatch
        end

      if error
        yield(error) if block_given?
        return nil
      end

      invitation
    end

    private

    def generate_token
      self.token ||= SecureRandom.urlsafe_base64(32)
    end

    def set_default_expiry
      self.expires_at ||= EXPIRY_WINDOW.from_now
    end
  end
end
