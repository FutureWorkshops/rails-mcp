class CreateRailsMcpInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :invitations do |t|
      t.references :account,    null: false, foreign_key: true
      t.bigint     :invited_by_id
      t.string     :email,      null: false
      t.string     :token,      null: false
      t.datetime   :expires_at, null: false
      t.datetime   :accepted_at
      t.datetime   :revoked_at
      t.timestamps
    end

    add_index :invitations, :token, unique: true
    add_index :invitations, :invited_by_id
    add_foreign_key :invitations, :users, column: :invited_by_id, on_delete: :nullify

    add_index :invitations, [ :account_id, :email ],
              unique: true,
              where: "accepted_at IS NULL AND revoked_at IS NULL",
              name: "index_invitations_pending_unique"
  end
end
