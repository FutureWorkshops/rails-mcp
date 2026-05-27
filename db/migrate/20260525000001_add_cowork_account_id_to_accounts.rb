class AddCoworkAccountIdToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :cowork_account_id, :string
    add_index  :accounts, :cowork_account_id, unique: true
  end
end
