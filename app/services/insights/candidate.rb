module Insights
  Candidate = Struct.new(
    :trigger_template,
    :workspace,
    :subject_type,
    :subject_id,
    :dimension_type,
    :dimension_id,
    :window_range,
    :baseline_range,
    :stats,
    :severity,
    :detection_id,
    keyword_init: true
  )
end
