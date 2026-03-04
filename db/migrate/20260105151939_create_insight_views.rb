# db/migrate/20260105000000_create_insight_views.rb
class CreateInsightViews < ActiveRecord::Migration[7.1]
  def change
    create_table :insight_views do |t|
      t.bigint :insight_id, null: false
      t.bigint :user_id,    null: false
      t.datetime :read_at

      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
    end

    add_index :insight_views, [:user_id, :read_at]
    add_index :insight_views, [:user_id, :insight_id], unique: true, name: "idx_insight_views_user_insight"
    add_index :insight_views, [:insight_id]

    add_foreign_key :insight_views, :insights
    add_foreign_key :insight_views, :users
  end
end
