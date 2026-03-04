class CreateBenchmarkReviewScenarioStates < ActiveRecord::Migration[7.1]
  def change
    create_table :benchmark_review_scenario_states do |t|
      t.references :user, null: false, foreign_key: true
      t.string :benchmark_set, null: false
      t.string :label_primary, null: false
      t.string :scenario_id, null: false
      t.boolean :done, null: false, default: false
      t.text :comment
      t.datetime :done_at

      t.timestamps
    end

    add_index :benchmark_review_scenario_states,
              [:user_id, :benchmark_set, :label_primary, :scenario_id],
              unique: true,
              name: "idx_benchmark_review_scenario_states_unique"

    add_index :benchmark_review_scenario_states,
              [:user_id, :benchmark_set, :done],
              name: "idx_benchmark_review_scenario_states_user_set_done"
  end
end
