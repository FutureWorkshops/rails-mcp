module RailsMcp
  class Account < ApplicationRecord
    self.table_name = "accounts"

    has_many :users,       class_name: "RailsMcp::User",       dependent: :destroy
    has_many :invitations, class_name: "RailsMcp::Invitation", dependent: :destroy

    validates :name, presence: true

    def onboarded?
      onboarded_at.present?
    end

    def mark_onboarded!
      update!(onboarded_at: Time.current) unless onboarded?
    end
  end
end
