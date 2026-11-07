class CreateMcpToolCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_tool_calls do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, foreign_key: { on_delete: :nullify }
      t.string  :tool_name, null: false
      t.boolean :read_only, null: false, default: false
      t.string  :outcome, null: false
      t.string  :error_class
      t.integer :duration_ms
      t.string  :client_name
      t.datetime :created_at, null: false
    end

    add_index :mcp_tool_calls, :created_at
    add_index :mcp_tool_calls, [ :user_id, :created_at ]
  end
end
