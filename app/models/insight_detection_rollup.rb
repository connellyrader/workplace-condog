class InsightDetectionRollup < ApplicationRecord
  belongs_to :workspace

  DIMENSION_TYPES = %w[metric submetric category].freeze
  SUBJECT_TYPES = %w[IntegrationUser Group Workspace].freeze

  validates :workspace, :subject_type, :subject_id, :dimension_type, :dimension_id, :posted_on, presence: true
  validates :dimension_type, inclusion: { in: DIMENSION_TYPES }
  validates :subject_type, inclusion: { in: SUBJECT_TYPES }

  # Increment rollup counts for a single detection.
  # Called from DetectionFetcher after saving each detection batch.
  # Uses upsert to create or update the rollup row atomically.
  def self.increment_for_detection!(
    workspace_id:,
    posted_on:,
    dimension_type:,
    dimension_id:,
    metric_id:,
    polarity:,
    logit_margin_min:,
    subject_type: "Workspace",
    subject_id: nil
  )
    return if workspace_id.blank? || posted_on.blank? || dimension_id.blank?

    subject_id ||= workspace_id if subject_type == "Workspace"
    positive_delta = polarity == "positive" ? 1 : 0
    negative_delta = polarity == "negative" ? 1 : 0

    # Use raw SQL for atomic upsert with increment
    connection.execute(sanitize_sql_array([<<~SQL, workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, posted_on, logit_margin_min, positive_delta, negative_delta]))
      INSERT INTO insight_detection_rollups
        (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, posted_on, logit_margin_min, total_count, positive_count, negative_count, created_at, updated_at)
      VALUES
        (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, NOW(), NOW())
      ON CONFLICT (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, logit_margin_min, posted_on)
      DO UPDATE SET
        total_count = insight_detection_rollups.total_count + 1,
        positive_count = insight_detection_rollups.positive_count + ?,
        negative_count = insight_detection_rollups.negative_count + ?,
        updated_at = NOW()
    SQL
  end

  # Batch increment for multiple detections (more efficient than calling increment_for_detection! in a loop)
  # Writes workspace-level rollups only. Call bulk_increment_for_groups! separately for group rollups.
  def self.bulk_increment_for_detections!(workspace_id:, detections_data:, logit_margin_min:)
    return if detections_data.blank?

    # Group by rollup key to sum up counts
    rollup_deltas = Hash.new { |h, k| h[k] = { total: 0, positive: 0, negative: 0 } }

    detections_data.each do |det|
      key = [det[:posted_on], det[:dimension_type], det[:dimension_id], det[:metric_id]]
      rollup_deltas[key][:total] += 1
      rollup_deltas[key][:positive] += 1 if det[:polarity] == "positive"
      rollup_deltas[key][:negative] += 1 if det[:polarity] == "negative"
    end

    rollup_deltas.each do |(posted_on, dimension_type, dimension_id, metric_id), counts|
      next if dimension_id.blank?

      connection.execute(sanitize_sql_array([<<~SQL, workspace_id, workspace_id, dimension_type, dimension_id, metric_id, posted_on, logit_margin_min, counts[:total], counts[:positive], counts[:negative], counts[:total], counts[:positive], counts[:negative]]))
        INSERT INTO insight_detection_rollups
          (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, posted_on, logit_margin_min, total_count, positive_count, negative_count, created_at, updated_at)
        VALUES
          (?, 'Workspace', ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
        ON CONFLICT (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, logit_margin_min, posted_on)
        DO UPDATE SET
          total_count = insight_detection_rollups.total_count + ?,
          positive_count = insight_detection_rollups.positive_count + ?,
          negative_count = insight_detection_rollups.negative_count + ?,
          updated_at = NOW()
      SQL
    end
  end

  # Batch increment for group-level rollups.
  # detections_data should include :integration_user_id for each detection.
  # This method looks up which groups the user belongs to and updates those rollups.
  def self.bulk_increment_for_groups!(workspace_id:, detections_data:, logit_margin_min:)
    return if detections_data.blank?

    # Collect all integration_user_ids
    iu_ids = detections_data.map { |d| d[:integration_user_id] }.compact.uniq
    return if iu_ids.empty?

    # Fetch group memberships for all users in one query
    group_memberships = GroupMember
      .joins(:group)
      .where(integration_user_id: iu_ids, groups: { workspace_id: workspace_id })
      .pluck(:integration_user_id, :group_id)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }

    # Group by (group_id, posted_on, dimension_type, dimension_id, metric_id) to sum counts
    rollup_deltas = Hash.new { |h, k| h[k] = { total: 0, positive: 0, negative: 0 } }

    detections_data.each do |det|
      iu_id = det[:integration_user_id]
      next unless iu_id

      group_ids = group_memberships[iu_id] || []
      group_ids.each do |gid|
        key = [gid, det[:posted_on], det[:dimension_type], det[:dimension_id], det[:metric_id]]
        rollup_deltas[key][:total] += 1
        rollup_deltas[key][:positive] += 1 if det[:polarity] == "positive"
        rollup_deltas[key][:negative] += 1 if det[:polarity] == "negative"
      end
    end

    rollup_deltas.each do |(group_id, posted_on, dimension_type, dimension_id, metric_id), counts|
      next if dimension_id.blank? || group_id.blank?

      connection.execute(sanitize_sql_array([<<~SQL, workspace_id, group_id, dimension_type, dimension_id, metric_id, posted_on, logit_margin_min, counts[:total], counts[:positive], counts[:negative], counts[:total], counts[:positive], counts[:negative]]))
        INSERT INTO insight_detection_rollups
          (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, posted_on, logit_margin_min, total_count, positive_count, negative_count, created_at, updated_at)
        VALUES
          (?, 'Group', ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
        ON CONFLICT (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, logit_margin_min, posted_on)
        DO UPDATE SET
          total_count = insight_detection_rollups.total_count + ?,
          positive_count = insight_detection_rollups.positive_count + ?,
          negative_count = insight_detection_rollups.negative_count + ?,
          updated_at = NOW()
      SQL
    end
  end
end
