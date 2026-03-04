class AddPgVectorAndKbChunks < ActiveRecord::Migration[7.1]
  def up
    # Always create the table itself
    create_table :kb_chunks do |t|
      t.string :namespace, null: false   # "signal_category" | "template" | "playbook"
      t.string :title,     null: false
      t.text   :body,      null: false   # curated guidance/definitions only
      t.string :source_ref
      t.jsonb  :meta,      null: false, default: {}
      t.timestamps
    end

    add_index :kb_chunks, :namespace
    add_index :kb_chunks, :source_ref

    # Only set up pgvector in production. In dev/test we skip this entirely.
    return unless Rails.env.production?

    enable_extension "vector" unless extension_enabled?("vector")

    execute <<~SQL
      ALTER TABLE kb_chunks
      ADD COLUMN IF NOT EXISTS embedding vector(1536);
    SQL

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS index_kb_chunks_on_embedding_ivf
      ON kb_chunks USING ivfflat (embedding vector_l2_ops)
      WITH (lists = 100);
    SQL
  end

  def down
    drop_table :kb_chunks
  end
end
