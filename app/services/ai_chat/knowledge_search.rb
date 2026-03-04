# app/services/ai_chat/knowledge_search.rb
module AiChat
  class KnowledgeSearch
    TOP_K = (ENV["KB_TOPK"] || 6).to_i

    # Search across: metric, submetric, signal_category, signal_subcategory
    def self.search(query:, kinds: %w[metric submetric signal_category signal_subcategory])
      emb = AiChat::EmbeddingService.embed_one!(query)
      conn = ActiveRecord::Base.connection
      quoted = Array(kinds).map { |k| conn.quote(k) }.join(",")
      ns_cond = quoted.present? ? "namespace IN (#{quoted})" : "TRUE"

      sql = <<~SQL
        SELECT id, namespace, title, body, source_ref, meta,
               (embedding <-> CAST(:emb AS vector)) AS distance
        FROM kb_chunks
        WHERE #{ns_cond}
        ORDER BY embedding <-> CAST(:emb AS vector)
        LIMIT :k
      SQL

      rows = conn.exec_query(sql, "kb_search", { emb: "{#{emb.join(',')}}", k: TOP_K })
      rows.map(&:symbolize_keys)
    rescue => e
      Rails.logger.error("[AiChat::KnowledgeSearch] #{e.class}: #{e.message}")
      []
    end
  end
end
