# db/migrate/20251021204230_add_polarity_to_detections.rb
class AddPolarityToDetections < ActiveRecord::Migration[7.1]
  def up
    add_column :detections, :polarity, :string, limit: 8, null: false unless column_exists?(:detections, :polarity)

    # Drop any old unique on (message_id, signal_category_id, model_test_id)
    if index_name_exists?(:detections, "index_msg_sigcat_unique")
      remove_index :detections, name: "index_msg_sigcat_unique"
    end
    if index_exists?(:detections, [:message_id, :signal_category_id, :model_test_id], unique: true)
      remove_index :detections, column: [:message_id, :signal_category_id, :model_test_id]
    end
    # Some schemas use a unique CONSTRAINT name; drop it if present.
    execute "ALTER TABLE detections DROP CONSTRAINT IF EXISTS index_msg_sigcat_unique;"

    # Add new unique including polarity
    unless index_name_exists?(:detections, "index_detections_on_msg_sc_mt_polarity")
      add_index :detections,
                [:message_id, :signal_category_id, :model_test_id, :polarity],
                unique: true,
                name: "index_detections_on_msg_sc_mt_polarity"
    end
  end

  def down
    remove_index :detections, name: "index_detections_on_msg_sc_mt_polarity" if
      index_name_exists?(:detections, "index_detections_on_msg_sc_mt_polarity")

    add_index :detections,
              [:message_id, :signal_category_id, :model_test_id],
              unique: true,
              name: "index_msg_sigcat_unique" unless
              index_name_exists?(:detections, "index_msg_sigcat_unique")

    remove_column :detections, :polarity if column_exists?(:detections, :polarity)
  end
end
