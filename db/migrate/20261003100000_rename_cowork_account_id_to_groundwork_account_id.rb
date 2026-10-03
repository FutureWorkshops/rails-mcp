# The identity provider for the MCP host family is Groundwork
# (groundwork.fws.io), so the mirrored account id column is named after it.
# Guarded so hosts that already renamed the column themselves (e.g.
# google-calendar-mcp-rails) migrate cleanly.
class RenameCoworkAccountIdToGroundworkAccountId < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:accounts, :cowork_account_id)
    return if column_exists?(:accounts, :groundwork_account_id)

    rename_column :accounts, :cowork_account_id, :groundwork_account_id
  end

  def down
    return unless column_exists?(:accounts, :groundwork_account_id)
    return if column_exists?(:accounts, :cowork_account_id)

    rename_column :accounts, :groundwork_account_id, :cowork_account_id
  end
end
