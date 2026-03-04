# frozen_string_literal: true

class Dashboard::SparklinePreview < Lookbook::Preview
  # @label Upward trend
  def default
    render "dashboard/components/sparkline", points: [40, 55, 62, 48, 72, 80, 65]
  end

  # @label Flat
  def flat
    render "dashboard/components/sparkline", points: [50, 52, 49, 51, 50, 48, 51]
  end

  # @label Downward trend
  def downward
    render "dashboard/components/sparkline", points: [90, 82, 75, 68, 55, 42, 38]
  end

  # @label Volatile
  def volatile
    render "dashboard/components/sparkline", points: [20, 80, 35, 90, 15, 75, 40]
  end
end
