# lib/tasks/signal_category_thresholds.rake
namespace :signals do
  desc "Scan trainer folders and update SignalCategory positive_threshold/negative_threshold. Usage: rake 'signals:update_thresholds[/abs/path/to/root]'"
  task :update_thresholds, [:root] => :environment do |_, args|
    root = args[:root].presence || Rails.root.join("trainer_exports").to_s
    raise "Root not found: #{root}" unless Dir.exist?(root)

    agg = Hash.new { |h,k| h[k] = { pos: [], neg: [] } }
    scanned = 0
    puts "🔎 Scanning trainer folders under: #{root}"

    Dir.children(root).sort.each do |child|
      dir = File.join(root, child)
      next unless File.directory?(dir)

      labels_path     = File.join(dir, "labels.json")
      thresholds_path = File.join(dir, "thresholds.json")
      next unless File.exist?(labels_path) && File.exist?(thresholds_path)

      begin
        labels     = JSON.parse(File.read(labels_path))
        thresholds = JSON.parse(File.read(thresholds_path))
      rescue => e
        warn "⚠️  Skipping #{dir}: JSON parse failed (#{e.class}: #{e.message})"
        next
      end

      id2label    = labels["id2label"] || {}
      arr         = thresholds["thresholds"] || []
      unless arr.is_a?(Array) && id2label.is_a?(Hash)
        warn "⚠️  Skipping #{dir}: unexpected shapes"
        next
      end

      # Accumulate thresholds per base label & polarity
      id2label.each do |id_str, label|
        idx = Integer(id_str) rescue nil
        next if idx.nil? || idx < 0 || idx >= arr.length

        thr  = arr[idx]
        lab  = label.to_s
        base = lab.sub(/_(Positive|Negative)\z/i, "")
        pol  = lab =~ /_Positive\z/i ? :pos : :neg
        agg[base][pol] << Float(thr) rescue nil
      end

      scanned += 1
      puts "  • processed #{child} (#{agg.size} bases so far)"
    end

    raise "No trainer folders found with labels.json + thresholds.json" if scanned.zero?

    # Compute means and update DB
    updates = 0
    ActiveRecord::Base.transaction do
      agg.each do |base, pols|
        pos_values = pols[:pos].compact
        neg_values = pols[:neg].compact

        pos_mean = pos_values.empty? ? nil : (pos_values.sum / pos_values.size.to_f)
        neg_mean = neg_values.empty? ? nil : (neg_values.sum / neg_values.size.to_f)

        # Find SignalCategory by normalized name (underscores/spaces tolerant)
        norm = base.downcase
        sc = SignalCategory.find_by("REPLACE(LOWER(name), ' ', '_') = ?", norm)
        unless sc
          # Optional second try if your table stores titles with spaces vs underscores
          sc = SignalCategory.find_by(name: base.tr("_", " "))
        end
        unless sc
          warn "⚠️  No SignalCategory row for #{base.inspect} — skipping"
          next
        end

        attrs = {}
        attrs[:positive_threshold] = pos_mean if pos_mean
        attrs[:negative_threshold] = neg_mean if neg_mean

        if attrs.empty?
          warn "⚠️  No thresholds for #{base.inspect} (pos=#{pos_values.size}, neg=#{neg_values.size})"
          next
        end

        sc.update!(attrs)
        updates += 1
        puts "  ✅ #{sc.name}: pos=#{pos_mean&.round(4)} neg=#{neg_mean&.round(4)}"
      end
    end

    puts "🏁 Done. Updated #{updates} SignalCategory rows from #{scanned} trainer folders."
  end
end
