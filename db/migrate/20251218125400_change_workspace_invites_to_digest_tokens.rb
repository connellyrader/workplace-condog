class ChangeWorkspaceInvitesToDigestTokens < ActiveRecord::Migration[7.1]
  def up
    add_column :workspace_invites, :token_digest, :string
    add_index  :workspace_invites, :token_digest, unique: true

    # Optional: backfill if any existing invites exist
    say_with_time "Backfilling workspace_invites.token_digest" do
      WorkspaceInvite.reset_column_information
      WorkspaceInvite.where.not(token: [nil, ""]).find_each do |invite|
        invite.update_columns(token_digest: WorkspaceInvite.digest_token(invite.token))
      end
    end

    remove_column :workspace_invites, :token, :string
  end

  def down
    add_column :workspace_invites, :token, :string
    remove_index  :workspace_invites, :token_digest
    remove_column :workspace_invites, :token_digest, :string
  end
end
