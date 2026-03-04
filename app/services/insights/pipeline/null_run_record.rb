module Insights
  module Pipeline
    class NullRunRecord
      attr_accessor :id, :workspace, :workspace_id, :snapshot_at, :mode, :status, :logit_margin_min
      attr_accessor :timings, :error_payload, :candidates_total, :candidates_primary, :accepted_primary, :persisted_count, :delivered

      def initialize(workspace:, snapshot_at:, mode:, status:, logit_margin_min:)
        @workspace = workspace
        @workspace_id = workspace&.id
        @snapshot_at = snapshot_at
        @mode = mode
        @status = status
        @logit_margin_min = logit_margin_min
        @timings = {}
        @error_payload = {}
        @id = nil
        @candidates_total = nil
        @candidates_primary = nil
        @accepted_primary = nil
        @persisted_count = nil
        @delivered = nil
      end

      def update!(attrs)
        attrs.each do |key, value|
          setter = "#{key}="
          public_send(setter, value) if respond_to?(setter)
        end
        true
      end
    end
  end
end
