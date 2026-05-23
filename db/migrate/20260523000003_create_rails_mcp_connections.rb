class CreateRailsMcpConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :connections do |t|
      t.references :user, null: false, foreign_key: true
      t.string :type, null: false
      t.string :name, null: false
      t.string :external_id, null: false

      t.text :access_token
      t.text :refresh_token
      t.datetime :token_expires_at
      t.boolean :token_active, null: false, default: true
      t.datetime :token_refresh_failed_at
      t.string :token_refresh_error

      t.timestamps
    end

    add_index :connections, [ :user_id, :external_id ], unique: true
    add_index :connections, [ :user_id, :type ]
  end
end
