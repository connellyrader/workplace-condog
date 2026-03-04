class CreateInsightPipelineAndFeedbackTables < ActiveRecord::Migration[7.1]
  def change
    create_table :insight_pipeline_runs do |t|
      t.bigint :workspace_id, null: false
      t.datetime :snapshot_at, null: false
      t.string :mode, null: false, default: "dry_run"
      t.string :status, null: false, default: "ok"
      t.decimal :logit_ratio_min, precision: 10, scale: 4, null: false, default: 0
      t.integer :candidates_total
      t.integer :candidates_primary
      t.integer :accepted_primary
      t.integer :persisted
      t.integer :delivered
      t.jsonb :timings, null: false, default: {}
      t.jsonb :errors, null: false, default: {}
      t.timestamps
    end

    add_index :insight_pipeline_runs, [:workspace_id, :snapshot_at], name: "idx_insight_pipeline_runs_workspace_snapshot"
    add_index :insight_pipeline_runs, [:workspace_id, :created_at], name: "idx_insight_pipeline_runs_workspace_created"
    add_foreign_key :insight_pipeline_runs, :workspaces

    create_table :workspace_insight_template_overrides do |t|
      t.bigint :workspace_id, null: false
      t.bigint :trigger_template_id, null: false
      t.boolean :enabled, null: false, default: true
      t.jsonb :overrides, null: false, default: {}
      t.timestamps
    end

    add_index :workspace_insight_template_overrides,
              [:workspace_id, :trigger_template_id],
              unique: true,
              name: "idx_workspace_template_overrides_unique"
    add_foreign_key :workspace_insight_template_overrides, :workspaces
    add_foreign_key :workspace_insight_template_overrides,
                    :insight_trigger_templates,
                    column: :trigger_template_id

    create_table :insight_feedback do |t|
      t.bigint :insight_id, null: false
      t.bigint :user_id
      t.string :rating, null: false
      t.string :reason_code
      t.text :comment
      t.timestamps
    end

    add_index :insight_feedback, [:insight_id, :created_at], name: "idx_insight_feedback_insight_created"
    add_index :insight_feedback, [:user_id, :created_at], name: "idx_insight_feedback_user_created"
    add_index :insight_feedback, [:insight_id, :user_id], unique: true, name: "idx_insight_feedback_unique_user"
    add_foreign_key :insight_feedback, :insights
    add_foreign_key :insight_feedback, :users
  end
end
