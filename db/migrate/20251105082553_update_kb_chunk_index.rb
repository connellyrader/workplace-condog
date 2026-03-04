class UpdateKbChunkIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # Ensure the column cannot be null (required for a reliable upsert key)
    change_column_null :kb_chunks, :source_ref, false

    # Add a unique index so INSERT ... ON CONFLICT (source_ref) works
    add_index :kb_chunks,
              :source_ref,
              unique: true,
              name: "idx_kb_chunks_source_ref",
              algorithm: :concurrently
  end
end
