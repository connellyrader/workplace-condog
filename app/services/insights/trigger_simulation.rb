module Insights
  # Orchestrates trigger-aware simulations by delegating to a driver-specific simulator.
  class TriggerSimulation
    Result = Struct.new(:params, :summary, :top_candidates, keyword_init: true)

    RATE_SPIKE_DRIVERS = %w[
      metric_negative_rate_spike
      metric_positive_rate_spike
      submetric_negative_rate_spike
      submetric_positive_rate_spike
      category_negative_rate_spike
      category_positive_rate_spike
      individual_negative_spike
      individual_positive_streak
    ].freeze

    DRIVER_SIMULATORS = RATE_SPIKE_DRIVERS.index_with { TriggerSimulators::MetricRateSpike }.merge(
      "category_volume_spike" => TriggerSimulators::CategoryVolumeSpike,
      "group_outlier_vs_org" => TriggerSimulators::GroupOutlierVsOrg,
      "group_bright_spot_vs_org" => TriggerSimulators::GroupOutlierVsOrg,
      "submetric_concentration_of_negatives" => TriggerSimulators::SubmetricConcentration,
      "submetric_concentration_of_positives" => TriggerSimulators::SubmetricConcentration,
      "metric_sustained_negative_rate" => TriggerSimulators::SustainedNegativeRate
    ).freeze

    def self.for_template(template:, workspace:, snapshot_at:, baseline_mode: "trailing", overrides: {}, logger: Rails.logger)
      new(
        template: template,
        workspace: workspace,
        snapshot_at: snapshot_at,
        baseline_mode: baseline_mode,
        overrides: overrides,
        logger: logger
      ).run!
    end

    def initialize(template:, workspace:, snapshot_at:, baseline_mode:, overrides:, logger: Rails.logger)
      @template = template
      @workspace = workspace
      @snapshot_at = snapshot_at
      @baseline_mode = baseline_mode.presence || "trailing"
      @overrides = overrides || {}
      @logger = logger
    end

    def run!
      simulator_class = simulator_for(template.driver_type)
      raise ArgumentError, "Unsupported driver_type #{template.driver_type}" unless simulator_class

      simulator_class.new(
        template: template,
        workspace: workspace,
        snapshot_at: snapshot_at,
        baseline_mode: baseline_mode,
        overrides: overrides,
        logger: logger
      ).run!
    end

    private

    attr_reader :template, :workspace, :snapshot_at, :baseline_mode, :overrides, :logger

    def simulator_for(driver_type)
      DRIVER_SIMULATORS[driver_type.to_s]
    end
  end
end
