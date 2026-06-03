module RailsMcp
  class User < ApplicationRecord
    self.table_name = "users"

    # Role within the user's current (mirrored) account, sourced from the SSO
    # IdP's userinfo `accounts[].role`. The engine models one current account
    # per user, so role is stored here rather than on a membership join.
    ROLES        = %w[member admin].freeze
    DEFAULT_ROLE = "member".freeze

    belongs_to :account, class_name: "RailsMcp::Account"

    has_many :connections,        class_name: "RailsMcp::Connection",  dependent: :destroy
    has_many :sent_invitations,   class_name: "RailsMcp::Invitation",
                                  foreign_key: :invited_by_id,
                                  dependent: :nullify

    validates :identity_id, presence: true, uniqueness: true
    validates :email,
              presence: true,
              uniqueness: { case_sensitive: false },
              format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :role, inclusion: { in: ROLES }

    normalizes :email, with: ->(e) { e.strip.downcase }

    def admin?
      role == "admin"
    end
  end
end
