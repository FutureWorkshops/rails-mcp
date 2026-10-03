module RailsMcp
  class Account < ApplicationRecord
    self.table_name = "accounts"

    has_many :users,       class_name: "RailsMcp::User",       dependent: :destroy

    validates :name, presence: true, length: { maximum: 100 }

  end
end
