module Clara
  class OverviewService
    EXPIRATION_WINDOW      = 1.week
    STALE_GENERATION_AFTER = 10.minutes
    MIN_DETECTIONS         = 15

    attr_reader :workspace, :metric, :user

    def initialize(workspace:, metric:, user:, range_start:, range_end:, group_scope:, member_ids:, logger: Rails.logger)
      @workspace   = workspace
      @metric      = metric
      @user        = user
      @range_start = range_start.to_date
      @range_end   = range_end.to_date
      @group_scope = group_scope
      @member_ids  = member_ids
      @logger      = logger
    end

    def latest
      scoped.first
    end

    def fresh
      record = latest
      record if record&.fresh?
    end

    def data_available?(min_detections: MIN_DETECTIONS)
      @data_available ||= {}
      return @data_available[min_detections] if @data_available.key?(min_detections)

      @data_available[min_detections] = detection_count >= min_detections.to_i
    end

    # Ensures there is a recent overview; if none exists or the most recent is expired,
    # we kick off a new generation in a background thread and stream tokens via ActionCable.
    def ensure_generation!(stream_key:)
      return nil unless data_available?

      overview       = nil
      should_generate = false

      ClaraOverview.transaction do
        overview = scoped.lock("FOR UPDATE").first

        # Already good
        if overview&.fresh?
          return overview
        end

        # If something is currently running and still fresh enough, reuse it.
        if overview && (overview.generating_status? || overview.pending_status?) && !stale_generation?(overview)
          return overview
        end

        overview = ClaraOverview.create!(
          workspace:    workspace,
          metric:       metric,
          range_start:  @range_start,
          range_end:    @range_end,
          group_scope:  @group_scope,
          status:       :generating,
          openai_model: model_name,
          request_id:   SecureRandom.uuid
        )
        should_generate = true
      end

      if should_generate
        broadcast_refreshing(overview, stream_key)
        start_generation_thread(overview, stream_key)
      end

      overview
    end

    def self.serialize(overview)
      return nil unless overview

      {
        id:           overview.id,
        metric_id:    overview.metric_id,
        workspace_id: overview.workspace_id,
        content:      overview.content,
        status:       overview.status,
        expired:      overview.expired?,
        range_start:  overview.range_start&.iso8601,
        range_end:    overview.range_end&.iso8601,
        group_scope:  overview.group_scope,
        generated_at: overview.generated_at&.iso8601,
        expires_at:   overview.expires_at&.iso8601
      }
    end

    private

    def scoped
      ClaraOverview
        .for_workspace_metric(workspace.id, metric.id)
        .for_range(@range_start, @range_end)
        .for_group_scope(@group_scope)
        .order(created_at: :desc)
    end

    def detection_count
      @detection_count ||= begin
        service = DashboardRollupService.new(
          workspace_id: workspace.id,
          logit_margin_min: (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f,
          group_member_ids: @member_ids
        )

        counts = service.aggregate_counts(
          start_date: @range_start,
          end_date: @range_end,
          metric_id: metric.id
        )

        counts[:tot].to_i
      end
    end

    def detection_scope
      window_start = @range_start.beginning_of_day
      window_end   = @range_end.end_of_day

      scope = Detection
                .joins(message: :integration, signal_category: :submetric)
                .where(integrations: { workspace_id: workspace.id })
                .where(submetrics: { metric_id: metric.id })
                .where("messages.posted_at >= ? AND messages.posted_at <= ?", window_start, window_end)
                .with_scoring_policy

      if @member_ids
        scope = scope.where(messages: { integration_user_id: @member_ids })
      end

      scope
    end

    def stale_generation?(overview)
      overview.updated_at < STALE_GENERATION_AFTER.ago
    end

    def model_name
      ENV.fetch("CLARA_OVERVIEW_MODEL", ENV.fetch("OPENAI_CHAT_MODEL", "gpt-4o-mini"))
    end

    def broadcast_refreshing(overview, stream_key)
      ActionCable.server.broadcast(
        stream_key,
        {
          type:     "refreshing",
          overview: self.class.serialize(overview)
        }
      )
    end

    def start_generation_thread(overview, stream_key)
      Thread.new do
        Rails.application.executor.wrap do
          begin
            Clara::OverviewGenerator.new(
              overview: overview,
              workspace: workspace,
              metric: metric,
              stream_key: stream_key,
              model: model_name,
              range_start: @range_start,
              range_end: @range_end,
              member_ids: @member_ids
            ).run!
          rescue => e
            @logger.error("[Clara::OverviewService] generation thread error: #{e.class}: #{e.message}")
          end
        end
      end
    end

    # logit_margin_threshold method removed - now using DetectionPolicy.sql_condition via with_scoring_policy scope
  end
end

