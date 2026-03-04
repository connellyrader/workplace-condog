class MakeBenchmarkLabelsCsvImportable < ActiveRecord::Migration[7.1]
  def up
    add_column :benchmark_labels, :benchmark_message_external_id, :string
    add_index :benchmark_labels, :benchmark_message_external_id

    execute <<~SQL
      CREATE OR REPLACE FUNCTION set_benchmark_label_message_id_from_external_id()
      RETURNS trigger AS $$
      BEGIN
        IF NEW.benchmark_message_id IS NULL AND NEW.benchmark_message_external_id IS NOT NULL THEN
          SELECT id
          INTO NEW.benchmark_message_id
          FROM benchmark_messages
          WHERE external_message_id = NEW.benchmark_message_external_id
          LIMIT 1;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_benchmark_labels_resolve_message_id ON benchmark_labels;
      CREATE TRIGGER trg_benchmark_labels_resolve_message_id
      BEFORE INSERT OR UPDATE ON benchmark_labels
      FOR EACH ROW
      EXECUTE FUNCTION set_benchmark_label_message_id_from_external_id();
    SQL

    change_column_null :benchmark_labels, :benchmark_message_id, true
  end

  def down
    change_column_null :benchmark_labels, :benchmark_message_id, false

    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_benchmark_labels_resolve_message_id ON benchmark_labels;
      DROP FUNCTION IF EXISTS set_benchmark_label_message_id_from_external_id();
    SQL

    remove_index :benchmark_labels, :benchmark_message_external_id
    remove_column :benchmark_labels, :benchmark_message_external_id
  end
end
