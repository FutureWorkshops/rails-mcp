# Hosts now store only SHA-256 hashes of OAuth tokens (Doorkeeper
# hash_token_secrets) and no longer fall back to looking tokens up in plain
# text: with that fallback, anyone who could read the table could present a
# stored hash as a bearer token. This hashes the rows still in plain text, the
# same way Doorkeeper::SecretStoring::Sha256Hash does, so connected clients
# keep working (they send the plaintext, which now hashes to the stored value).
#
# Hashed values are 64 lowercase hex characters; Doorkeeper's plaintext tokens
# are urlsafe base64, so they never look like that and only plain rows change.
# Irreversible by design.
class HashExistingOauthTokens < ActiveRecord::Migration[8.1]
  HASHED = /\A[0-9a-f]{64}\z/

  def up
    hash_column(:oauth_access_tokens, :token)
    hash_column(:oauth_access_tokens, :refresh_token)
    hash_column(:oauth_access_grants, :token)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def hash_column(table, column)
    return unless table_exists?(table) && column_exists?(table, column)

    rows = select_rows("SELECT id, #{column} FROM #{table} WHERE #{column} IS NOT NULL")
    rows.each do |id, value|
      next if value.match?(HASHED)

      execute(sanitize_sql([ "UPDATE #{table} SET #{column} = ? WHERE id = ?", Digest::SHA256.hexdigest(value), id ]))
    end
  end

  def sanitize_sql(args)
    ActiveRecord::Base.sanitize_sql_array(args)
  end
end
