start_ts = Time.utc(2025,12,1)
end_ts = Time.utc(2026,1,1)
rows = ActiveRecord::Base.connection.exec_query(<<~SQL)
  SELECT DISTINCT m.id, m.posted_at, m.subtext
  FROM detections d
  JOIN messages m ON m.id = d.message_id
  LEFT JOIN signal_categories sc ON sc.id = d.signal_category_id
  LEFT JOIN submetrics sm ON sm.id = sc.submetric_id
  LEFT JOIN metrics mt ON mt.id = COALESCE(d.metric_id, sm.metric_id)
  WHERE m.integration_id = 59
    AND m.posted_at >= '#{start_ts.iso8601}'
    AND m.posted_at < '#{end_ts.iso8601}'
    AND d.polarity = 'negative'
    AND LOWER(mt.name) = 'craft quality'
  ORDER BY m.posted_at ASC;
SQL
puts "COUNT=#{rows.length}"
rows.each do |r|
  sub = r['subtext'].to_s.gsub(/\s+/, ' ').strip
  puts "#{r['posted_at']} | msg_id=#{r['id']} | #{sub}"
end
