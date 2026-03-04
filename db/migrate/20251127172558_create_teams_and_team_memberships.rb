class CreateTeamsAndTeamMemberships < ActiveRecord::Migration[7.1]
  def change
    create_table :teams do |t|
      t.references :integration, null: false, foreign_key: true
      t.string  :ms_team_id, null: false
      t.string  :name,       null: false
      t.text    :description
      t.timestamps
    end

    add_index :teams, [:integration_id, :ms_team_id], unique: true

    create_table :team_memberships do |t|
      t.references :team,             null: false, foreign_key: true
      t.references :integration_user, null: false, foreign_key: true
      t.timestamps
    end

    add_index :team_memberships, [:team_id, :integration_user_id], unique: true

    # allow Teams channels to have nil slack_channel_id
    change_column_null :channels, :slack_channel_id, true
  end
end
