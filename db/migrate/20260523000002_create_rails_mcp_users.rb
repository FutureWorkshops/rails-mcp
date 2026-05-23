class CreateRailsMcpUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.references :account, null: false, foreign_key: true
      t.string :email,       null: false
      t.string :name
      t.string :identity_id, null: false
      t.timestamps
    end

    add_index :users, :email,       unique: true
    add_index :users, :identity_id, unique: true
  end
end
