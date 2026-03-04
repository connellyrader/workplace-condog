# lib/tasks/kb_index.rake
require "set"

namespace :kb do
  desc "Index signal-category + metric + submetric definitions into pgvector KB (no templates/playbooks)"
  task index: :environment do
    batch   = (ENV["BATCH"]  || 8).to_i
    pause   = (ENV["SLEEP"]  || 1.5).to_f
    max_re  = (ENV["MAX_RETRIES"] || 8).to_i
    backoff = (ENV["BACKOFF"] || 1.0).to_f
    verbose = ENV["VERBOSE"] == "1"

    rows = []

    # 1) Signal categories
    SignalCategory.includes(:submetric).find_each do |sc|
      body = [sc.description.presence, sc.submetric&.description.presence].compact.join("\n\n")
      next if body.blank?
      rows << {
        namespace: "signal_category",
        title: sc.name.to_s,
        body:  body,
        source_ref: "signal_categories:#{sc.id}",
        meta: {}
      }
    end

    # 2) Metrics
    Metric.find_each do |m|
      next if m.description.blank?
      rows << {
        namespace: "metric",
        title: m.name.to_s,
        body:  m.description.to_s,
        source_ref: "metrics:#{m.id}",
        meta: { reverse: m.reverse, framework_id: m.framework_id }
      }
    end

    # 3) Submetrics
    Submetric.includes(:metric).find_each do |sm|
      parts = [sm.description.presence]
      parts << "Metric: #{sm.metric&.name}" if sm.metric&.name.present?
      body = parts.compact.join("\n\n")
      next if body.blank?
      rows << {
        namespace: "submetric",
        title: sm.name.to_s,
        body:  body,
        source_ref: "submetrics:#{sm.id}",
        meta: { metric_id: sm.metric_id }
      }
    end

    existing_refs = AiChat::KbChunk.where(source_ref: rows.map { |r| r[:source_ref] }).pluck(:source_ref).to_set
    pending       = rows.reject { |r| existing_refs.include?(r[:source_ref]) }

    total_batches = (pending.size.to_f / batch).ceil
    puts "Indexing #{pending.size} chunks (batch=#{batch}, sleep=#{pause}s)…"

    conn = ActiveRecord::Base.connection

    pending.each_slice(batch).with_index(1) do |slice, i|
      texts = slice.map { |r| r[:body] }
      if verbose
        sum_chars  = texts.sum(&:length)
        approx_tok = (sum_chars / 4.0).ceil
        puts "  ▸ batch #{i}/#{total_batches}: inputs=#{slice.size} chars≈#{sum_chars} toks≈#{approx_tok}"
      end

      embs = AiChat::EmbeddingService.embed_retrying!(texts,
                max_retries: max_re, base_sleep: backoff, label: "kb_index")

      slice.zip(embs).each { |attrs, emb| upsert_kb!(conn, attrs, emb) }

      puts "    ✓ saved #{slice.size}" if verbose
      sleep(pause) if i < total_batches
    end

    puts "Done."
  end
end

def upsert_kb!(conn, attrs, embedding, dims: (ENV["OPENAI_EMBED_DIMS"] || 1536).to_i)
  ns   = conn.quote(attrs[:namespace])
  ttl  = conn.quote(attrs[:title])
  body = conn.quote(attrs[:body])
  sref = conn.quote(attrs[:source_ref])
  meta = conn.quote(attrs[:meta].to_json)

  floats  = Array(embedding).map { |x| x.to_f }
  if floats.empty? || (dims > 0 && floats.length != dims)
    raise "Embedding length #{floats.length} does not match column dims #{dims}. " \
          "Set OPENAI_EMBED_DIMS to match or re-create the column."
  end

  vec_sql = "CAST(ARRAY[#{floats.join(',')}] AS vector(#{dims}))"

  sql = <<~SQL
    INSERT INTO kb_chunks(namespace, title, body, source_ref, meta, embedding, created_at, updated_at)
    VALUES (#{ns}, #{ttl}, #{body}, #{sref}, #{meta}, #{vec_sql}, NOW(), NOW())
    ON CONFLICT (source_ref)
    DO UPDATE SET
      title      = EXCLUDED.title,
      body       = EXCLUDED.body,
      meta       = EXCLUDED.meta,
      embedding  = EXCLUDED.embedding,
      updated_at = NOW();
  SQL

  conn.execute(sql)
end
