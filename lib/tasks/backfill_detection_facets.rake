# lib/tasks/detections_backfill_facets.rake
require "json"

namespace :detections do
  # Usage examples:
  #   rails detections:backfill_facets
  #   rails detections:backfill_facets BATCH=2000 VERBOSE=1
  #   rails detections:backfill_facets DRY=1
  #
  # What it does:
  #   1) Fast SQL join to fill metric_id & submetric_id based on signal_category_id.
  #   2) Batch walk to infer signal_subcategory_id from full_output["label"].
  #
  # Assumptions:
  #   - detections.signal_category_id is present/valid
  #   - signal_categories.submetric_id present where applicable
  #   - submetrics.metric_id present where applicable
  #   - signal_subcategories belong to signal_categories (FK)
  desc "Backfill detections.metric_id, detections.submetric_id, detections.signal_subcategory_id"
  task backfill_facets: :environment do
    batch   = (ENV["BATCH"]   || 1000).to_i
    dry     = (ENV["DRY"]     == "1" || ENV["DRY_RUN"] == "1")
    verbose = (ENV["VERBOSE"] == "1")

    puts "== Backfilling metric_id & submetric_id (SQL join)…"
    sql = <<~SQL
      UPDATE detections d
      SET submetric_id = sc.submetric_id,
          metric_id = sm.metric_id
      FROM signal_categories sc
      LEFT JOIN submetrics sm ON sm.id = sc.submetric_id
      WHERE d.signal_category_id = sc.id
        AND (d.submetric_id IS DISTINCT FROM sc.submetric_id
             OR d.metric_id IS DISTINCT FROM sm.metric_id)
    SQL
    unless dry
      updated = ActiveRecord::Base.connection.execute(sql)
    end
    puts "   ✓ metric/submetric alignment complete#{' (DRY RUN)' if dry}"

    # Build subcategory lookup once: { signal_category_id => [[norm_name, subcat_id], ...] }
    puts "== Preparing subcategory lookup…" if verbose
    sub_map = Hash.new { |h,k| h[k] = [] }
    SignalSubcategory.find_each do |s|
      norm = normalize_name(s.name)
      next if norm.blank?
      sub_map[s.signal_category_id] << [norm, s.id]
    end
    puts "   ✓ #{sub_map.values.sum(&:size)} subcategory keys loaded" if verbose

    # Candidates: only where subcategory is NULL
    scope = Detection.where(signal_subcategory_id: nil)
    total = scope.count
    puts "== Backfilling signal_subcategory_id (candidates=#{total}, batch=#{batch})"

    processed = 0
    matched   = 0

    scope.in_batches(of: batch) do |batch_rel|
      rows = batch_rel.select(:id, :signal_category_id, :full_output).to_a

      # Resolve matches
      updates = []
      rows.each do |d|
        label = extract_label(d.full_output)
        next unless label

        base       = label.sub(/_(Positive|Negative)\z/i, "")
        norm_label = normalize_name(base)
        pairs      = sub_map[d.signal_category_id] || []

        # Strong match: whole-word (space/underscore) boundary
        chosen = pairs.find do |(norm_sub, _)|
          # Compare on space-word boundary to reduce accidental substring picks
          /\b#{Regexp.escape(norm_sub.gsub('_',' '))}\b/.match?(norm_label.gsub('_',' '))
        end
        # Fallback: substring containment
        chosen ||= pairs.find { |(norm_sub, _)| norm_label.include?(norm_sub) }

        if chosen
          updates << [d.id, chosen[1]]
        end
      end

      # Bulk update with CASE
      if updates.any? && !dry
        ids = updates.map(&:first)
        case_sql = updates.map { |id, sid| "WHEN #{id} THEN #{sid}" }.join(" ")
        upd_sql  = "UPDATE detections SET signal_subcategory_id = CASE id #{case_sql} END WHERE id IN (#{ids.join(',')})"
        ActiveRecord::Base.connection.execute(upd_sql)
      end

      processed += rows.size
      matched   += updates.size
      puts "   ▸ processed=#{processed}/#{total} matched=#{matched} (this_batch=#{updates.size})" if verbose
    end

    puts "== Done. matched_subcategories=#{matched}#{' (DRY RUN)' if dry}"
  end

  # --- helpers ---------------------------------------------------------------

  def normalize_name(str)
    s = str.to_s.downcase
    # make underscores the canonical separator
    s = s.gsub(/[^\p{Alnum}]+/, "_")
    s = s.gsub(/_+/, "_")
    s.sub(/^_/, "").sub(/_$/, "")
  end

  def extract_label(full_output)
    # full_output may be:
    #   - Hash (jsonb)  => {"label"=>"...", "logit"=>...}
    #   - String (JSON) => "{\"label\":\"...\",\"logit\":...}"
    #   - Something else → nil
    case full_output
    when Hash
      full_output["label"] || full_output[:label]
    when String
      begin
        parsed = JSON.parse(full_output) rescue nil
        parsed.is_a?(Hash) ? (parsed["label"] || parsed[:label]) : nil
      rescue
        nil
      end
    else
      # ActiveRecord::Type::Json casted values may behave like Hash
      if full_output.respond_to?(:[]) && full_output.respond_to?(:keys)
        full_output["label"] || full_output[:label]
      else
        nil
      end
    end
  end
end
