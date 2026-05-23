class CreateRailsMcpAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.datetime :onboarded_at
      t.timestamps
    end
  end
end
