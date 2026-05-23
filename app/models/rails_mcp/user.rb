module RailsMcp
  class User < ApplicationRecord
    self.table_name = "users"

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

    normalizes :email, with: ->(e) { e.strip.downcase }
  end
end
