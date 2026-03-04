class CreatePromptTestRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :prompt_test_runs do |t|
      t.string     :prompt_key, null: false
      t.string     :prompt_type
      t.references :prompt_version, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string     :title
      t.text       :body
      t.jsonb      :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :prompt_test_runs, [:prompt_key, :prompt_version_id, :created_at], name: "index_prompt_test_runs_on_key_version_created"
  end
end
