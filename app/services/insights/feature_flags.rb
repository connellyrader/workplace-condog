module Insights
  module FeatureFlags
    def self.v2_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("INSIGHTS_V2_ENABLED", "false"))
    end
  end
end
